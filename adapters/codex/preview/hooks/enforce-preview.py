#!/usr/bin/env python3
"""Fail-closed tool gate for an already identified N1 Codex preview worker."""

import json
import shlex
import sys


def deny(reason: str) -> dict:
    """Return the documented Codex PreToolUse denial shape."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }


def allowed_reader_command(command: str, executable: str, reader: str) -> bool:
    """Accept only the canonical four-argument trusted reader command."""
    try:
        argv = shlex.split(command, posix=True)
    except (TypeError, ValueError):
        return False
    return (len(argv) == 4 and argv[:2] == [executable, reader]
            and argv[2] in {"read", "search"}
            and command == shlex.join(argv))


def decision(tool_name: str, command: str, worker_scoped: bool,
             executable: str, reader: str) -> dict:
    """Deny every worker tool except the controller-bound reader bridge."""
    if not worker_scoped:
        return {}
    if (tool_name == "exec_command"
            and allowed_reader_command(command, executable, reader)):
        return {}
    return deny("N1 preview workers may use only the bound read/search bridge")


def handle_payload(payload: object, worker_scoped: bool,
                   executable: str, reader: str) -> dict:
    """Apply the gate only after native worker scope was independently proven."""
    if not worker_scoped:
        return {}
    if type(payload) is not dict or type(payload.get("tool_name")) is not str:
        return deny("N1 preview worker scope or tool input is unavailable")
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if type(tool_input) is dict else None
    if type(command) is not str:
        command = ""
    return decision(payload["tool_name"], command, True, executable, reader)


def main(argv: list[str] | None = None) -> int:
    """Run only from a controller-rendered worker hook configuration."""
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 3 or argv[0] != "--worker-scoped":
        return 2
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, UnicodeError):
        payload = None
    print(json.dumps(handle_payload(payload, True, argv[1], argv[2])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
