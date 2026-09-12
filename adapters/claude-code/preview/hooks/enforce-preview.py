#!/usr/bin/env python3
"""Second-layer read-only gate for qualified N1 preview worker hook events.

Agent frontmatter supplies the primary, pre-dispatch allowlist.  This hook only
applies a deny decision after the host has identified an event as a preview
worker; unknown events deliberately remain production passthrough.
"""

import json
from pathlib import Path
import sys


READ_ONLY_TOOLS = {"Read", "Grep", "Glob"}
RUNTIME_WORKER_IDENTITIES = {
    "n1:n1-runtime-code-reviewer",
    "n1:n1-runtime-security-reviewer",
    "n1:n1-runtime-review-verifier",
}
DENIAL = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": "N1 runtime reviewers are read-only",
    }
}


def decision(tool_name: str, registered_worker: bool) -> dict:
    """Return a native hook decision without changing unrelated events."""
    if not registered_worker or tool_name in READ_ONLY_TOOLS:
        return {}
    return DENIAL


def _path_is_allowed(value: object, roots: tuple[str, ...]) -> bool:
    if type(value) is not str or not value.startswith("/") or not roots:
        return False
    try:
        candidate = Path(value).resolve(strict=False)
        return any(candidate.is_relative_to(Path(root).resolve(strict=False)) for root in roots)
    except (OSError, ValueError):
        return False


def handle_payload(payload: object, worker_scoped: bool, roots: tuple[str, ...] = ()) -> dict:
    """Fail closed only for a hook invocation already scoped to a preview worker."""
    if not worker_scoped:
        return {}
    if type(payload) is not dict or type(payload.get("tool_name")) is not str:
        return DENIAL
    result = decision(payload["tool_name"], True)
    if result:
        return result
    tool_input = payload.get("tool_input")
    field = "file_path" if payload["tool_name"] == "Read" else "path"
    if type(tool_input) is not dict or not _path_is_allowed(tool_input.get(field), roots):
        return DENIAL
    return {}


def _preview_worker(payload: object) -> bool:
    """Recognize only an explicit host worker type; absence is not registration."""
    if type(payload) is not dict:
        return False
    for field in ("subagent_type", "agent_type"):
        value = payload.get(field)
        if type(value) is str and value in RUNTIME_WORKER_IDENTITIES:
            return True
    return False


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    worker_scoped = bool(argv) and argv[0] == "--worker-scoped"
    roots = tuple(argv[1:]) if worker_scoped else ()
    if argv and (not worker_scoped or any(not root.startswith("/") for root in roots)):
        return 2
    try:
        payload = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        payload = None
    print(json.dumps(handle_payload(payload, worker_scoped or _preview_worker(payload), roots)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
