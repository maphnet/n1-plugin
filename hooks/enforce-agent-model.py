#!/usr/bin/env python3
"""PreToolUse hook (Task tool): enforce config model overrides for n1 agent spawns.

The orchestrator is instructed to resolve `models.<agent>` from config and pass it to
every spawn — but that contract is instructions-only and occasionally missed (dogfood
finding I14: one of five spawns served on the frontmatter default despite an override).
This hook makes the override deterministic: if config defines a model for the spawned
n1 agent and the Task input carries a different (or no) model, rewrite it.

Fail-open by design: any parse problem, non-n1 agent, or missing override → no output
(hook exit 0 with empty stdout = passthrough).

Usage: enforce-agent-model.py <config_file>   (hook payload on stdin)
"""

import json
import sys


def resolve_override(config: dict, subagent_type: str) -> str | None:
    if not subagent_type.startswith("n1:"):
        return None
    agent = subagent_type[len("n1:"):]
    override = (config.get("models") or {}).get(agent)
    return override if isinstance(override, str) and override else None


def main() -> int:
    try:
        config = json.loads(open(sys.argv[1], encoding="utf-8").read())
        payload = json.loads(sys.stdin.read())
    except (IndexError, OSError, json.JSONDecodeError, ValueError):
        return 0

    if payload.get("tool_name") not in ("Task", "Agent"):
        return 0
    tool_input = payload.get("tool_input") or {}
    subagent = tool_input.get("subagent_type") or tool_input.get("subagent_name") or ""
    override = resolve_override(config, subagent)
    if not override or tool_input.get("model") == override:
        return 0

    updated = {**tool_input, "model": override}
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"n1 config override: models.{subagent[3:]} = {override}",
            "updatedInput": updated,
        }
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
