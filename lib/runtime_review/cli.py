"""Controller CLI. Native adapters collect observations and execute actions.

The Bash bridge supplies trusted --home and --config-file values. The reader
command is controller-only: adapters must bind root outside worker arguments.
No command resumes a lost session, launches a worker, or accepts an output path.
"""

import argparse
import json
from pathlib import Path
import sys

from .contract import HOSTS, ROLES, validate_capabilities
from .models import resolve_policy
from .reader import MAX_FILE_BYTES, read_file, search_files
from .source import parse_target, prepare_source
from .store import check_platform, create_run, load_state, local_report, resolve_run, save_raw_result, save_state
from .workflow import REVIEWERS, TERMINAL, advance, new_state


def _unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("JSON contains duplicate key: " + key)
        value[key] = item
    return value


def _json_file(path):
    path = Path(path).absolute()
    text = read_file(path.parent, path.name)
    return json.loads(text, object_pairs_hook=_unique_keys)


def _qualification_inputs(args):
    if args.capabilities != "-" and args.observed != "-":
        return _json_file(args.capabilities), _json_file(args.observed)
    if args.capabilities != "-" or args.observed != "-":
        raise ValueError("capabilities and observed must both use the qualification stream")
    raw = sys.stdin.buffer.read(MAX_FILE_BYTES + 1)
    if len(raw) > MAX_FILE_BYTES:
        raise ValueError("qualification stream byte limit exceeded")
    try:
        envelope = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_keys)
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise ValueError("qualification stream is malformed") from exc
    if type(envelope) is not dict or set(envelope) != {"capabilities", "observed"}:
        raise ValueError("qualification stream must contain capabilities and observed")
    return envelope["capabilities"], envelope["observed"]


def _qualification(args):
    check_platform()
    capabilities, observed = _qualification_inputs(args)
    report = validate_capabilities(capabilities, observed)
    if report["host"] != args.host:
        raise ValueError("host must match capability report and native observations")
    config = _json_file(args.config_file)
    policies = {role: resolve_policy(config, args.host, role) for role in sorted(ROLES)}
    for role, policy in policies.items():
        if report["models"][role] != policy:
            raise ValueError("models." + role + " must match trusted configuration")
    return report, policies


def _locations(state, event):
    result = event.get("result")
    if event.get("kind") != "result" or not isinstance(result, dict):
        return
    if result["status"] == "completed" and result["role"] in REVIEWERS:
        root = Path(state["workers"][result["role"]]["request"]["cwd"])
        for finding in result["output"]["findings"]:
            text = read_file(root, finding["file"])
            if finding["line"] > len(text.splitlines()):
                raise ValueError("finding.line is outside the pinned source file")


def _dispatch(args):
    if args.command in {"preflight", "prepare"}:
        if args.command == "prepare":
            parse_target(args.target)
        report, policies = _qualification(args)
        if args.command == "preflight":
            return report, 0
        run = create_run(Path(args.home))
        prepared = prepare_source(args.target, run)
        state = new_state(run.name, args.host, prepared, policies)
        state, actions = advance(state, {"kind": "start", "eventId": "start", "runId": run.name})
        save_state(run, state, 0)
        return {"runId": run.name, "generation": state["generation"], "status": state["status"], "actions": actions}, 0
    if args.command == "reader":
        result = read_file(Path(args.root), args.value) if args.operation == "read" else search_files(Path(args.root), args.value)
        return result, 0
    run = resolve_run(Path(args.home), args.run)
    if args.command == "report":
        state, report = local_report(run)
        return {"runId": run.name, "status": state["status"], "report": report}, 0 if state["status"] == "completed" else 3
    state = load_state(run)
    event = _json_file(args.file)
    if type(event) is not dict:
        raise ValueError("event must be an object")
    # rawText is adapter-captured diagnostic evidence, not part of the reducer
    # event or T2 envelope. Every accepted worker result retains it separately.
    has_raw = "rawText" in event
    raw = event.pop("rawText", None)
    if event.get("kind") == "result":
        if not has_raw or type(raw) is not str or len(raw.encode("utf-8")) > MAX_FILE_BYTES:
            raise ValueError("result events require bounded adapter-captured rawText")
    elif has_raw:
        raise ValueError("rawText is only permitted as bounded text on a result event")
    updated, actions = advance(state, event)
    _locations(state, event)
    save_state(run, updated, state["generation"])
    if event["kind"] == "result":
        save_raw_result(run, event["result"]["requestId"], raw)
    status = updated["status"]
    return {"runId": run.name, "generation": updated["generation"], "status": status, "actions": actions}, (
        3 if status in TERMINAL and status != "completed" else 0)


class _TrustedOption(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        if getattr(namespace, self.dest, None) is not None:
            parser.error(option_string + " is controller-owned and cannot be repeated")
        setattr(namespace, self.dest, values)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--home", required=True, action=_TrustedOption)
    parser.add_argument("--config-file", required=True, action=_TrustedOption)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "prepare"):
        command = commands.add_parser(name, allow_abbrev=False)
        command.add_argument("--host", choices=sorted(HOSTS), required=True)
        command.add_argument("--capabilities", required=True)
        command.add_argument("--observed", required=True)
        if name == "prepare":
            command.add_argument("--target", required=True)
    command = commands.add_parser("event", allow_abbrev=False)
    command.add_argument("--run", required=True)
    command.add_argument("--file", required=True)
    command = commands.add_parser("report", allow_abbrev=False)
    command.add_argument("--run", required=True)
    command = commands.add_parser("reader", allow_abbrev=False)
    command.add_argument("operation", choices=("read", "search"))
    command.add_argument("--root", required=True)
    command.add_argument("--value", required=True)
    args = parser.parse_args(argv)
    try:
        value, code = _dispatch(args)
        print(json.dumps(value, ensure_ascii=False, allow_nan=False))
        return code
    except (ValueError, UnicodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except (OSError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
