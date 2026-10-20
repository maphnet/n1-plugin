#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>`) and the persona's frontmatter has a `tools:` list: deny any tool outside it.
This duplicates native enforcement as a backstop. Denial: exit 2, reason on stderr.

Case 2 - spawn model override. For spawn tools targeting an N1 persona, rewrite `model`
from config `models.<persona>` (string, or a legacy host-keyed object read through its
"claude-code" key).

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root>   (payload on stdin)
"""

import json
import re
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}


def persona_of(agent_type: str):
    if agent_type.startswith("n1:"):
        return agent_type[len("n1:"):]
    return None


def model_override(config: dict, persona: str):
    entry = (config.get("models") or {}).get(persona)
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        value = entry.get("claude-code")
        if isinstance(value, str):
            return value or None
        if isinstance(value, dict):
            return value.get("model") or None
    return None


def persona_tools(plugin_root: str, persona: str):
    """Set of tool names from the persona frontmatter, or None when the persona inherits all tools."""
    try:
        text = (Path(plugin_root) / "agents" / f"{persona}.md").read_text(encoding="utf-8")
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    m = re.search(r"^tools:\s*(.+)$", text[3:end], re.M)
    if not m:
        return None
    return {t.strip() for t in m.group(1).split(",") if t.strip()}


def restriction(payload: dict, plugin_root: str) -> int:
    persona = persona_of(str(payload.get("agent_type") or ""))
    tool = str(payload.get("tool_name") or "")
    if not persona or not tool:
        return 0
    allowed = persona_tools(plugin_root, persona)
    if allowed is None or tool.startswith("mcp__"):
        return 0
    ok = tool in allowed
    if ok:
        return 0
    sys.stderr.write(f"N1: persona {persona} may not use tool {tool} (allowed: {', '.join(sorted(allowed))})\n")
    return 2


def spawn_override(payload: dict, config: dict) -> int:
    if payload.get("tool_name") not in SPAWN_TOOLS:
        return 0
    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("subagent_type") or tool_input.get("subagent_name") or tool_input.get("agent_type") or ""
    persona = persona_of(str(target))
    if not persona:
        return 0
    override = model_override(config, persona)
    if not override or tool_input.get("model") == override:
        return 0
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": f"n1 config override: models.{persona} = {override}",
            "updatedInput": {**tool_input, "model": override},
        }
    }))
    return 0


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    config_file = sys.argv[1] if len(sys.argv) > 1 else ""
    plugin_root = sys.argv[2] if len(sys.argv) > 2 else ""
    config = {}
    if config_file:
        try:
            config = json.loads(Path(config_file).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
    if not isinstance(config, dict):
        config = {}
    rc = restriction(payload, plugin_root)
    if rc:
        return rc
    return spawn_override(payload, config)


if __name__ == "__main__":
    sys.exit(main())
