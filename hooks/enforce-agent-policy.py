#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy, identical on Claude Code and Codex.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>` on Claude, `n1-<p>` on Codex) and the persona's frontmatter has a `tools:` list:
deny any tool outside it. On Claude this duplicates native enforcement; on Codex it is the
only enforcement. Codex has no per-capability tools, so its tools map onto the classes
personas declare (CODEX_TOOL_CLASS); unmapped Codex tools (shell, update_plan, MCP) pass,
and read-only personas rely on sandbox_mode = "read-only" in their generated TOML.
Denial: exit 2, reason on stderr.

Case 2 - spawn model override. tool_name is a spawn tool (Task/Agent on Claude,
spawn_agent on Codex) targeting an N1 persona: rewrite `model` from config
`models.<persona>` (string = Claude only; object keyed by host). Same contract as the
former enforce-agent-model.py (dogfood finding I14).

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root> <host>   (payload on stdin)
"""

import json
import re
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}
CODEX_TOOL_CLASS = {
    "apply_patch": "Edit",
    "spawn_agent": "Agent", "send_input": "Agent", "wait_agent": "Agent", "close_agent": "Agent",
    "web_search": "WebSearch",
}


def persona_of(agent_type: str):
    for prefix in ("n1:", "n1-"):
        if agent_type.startswith(prefix):
            return agent_type[len(prefix):]
    return None


def model_override(config: dict, persona: str, host: str):
    entry = (config.get("models") or {}).get(persona)
    if isinstance(entry, str):
        return entry if host == "claude-code" else None
    if isinstance(entry, dict):
        value = entry.get(host)
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


def restriction(payload: dict, plugin_root: str, host: str) -> int:
    persona = persona_of(str(payload.get("agent_type") or ""))
    tool = str(payload.get("tool_name") or "")
    if not persona or not tool:
        return 0
    allowed = persona_tools(plugin_root, persona)
    if allowed is None or tool.startswith("mcp__"):
        return 0
    cls = CODEX_TOOL_CLASS.get(tool)
    if cls == "Edit":
        ok = bool({"Edit", "Write"} & allowed)
    elif cls:
        ok = cls in allowed
    elif host == "codex":
        ok = True
    else:
        ok = tool in allowed
    if ok:
        return 0
    sys.stderr.write(f"N1: persona {persona} may not use tool {tool} (allowed: {', '.join(sorted(allowed))})\n")
    return 2


def spawn_override(payload: dict, config: dict, host: str) -> int:
    if payload.get("tool_name") not in SPAWN_TOOLS:
        return 0
    tool_input = payload.get("tool_input") or {}
    target = tool_input.get("subagent_type") or tool_input.get("subagent_name") or tool_input.get("agent_type") or ""
    persona = persona_of(str(target))
    if not persona:
        return 0
    override = model_override(config, persona, host)
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
    host = sys.argv[3] if len(sys.argv) > 3 else "claude-code"
    config = {}
    if config_file:
        try:
            config = json.loads(Path(config_file).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
    rc = restriction(payload, plugin_root, host)
    if rc:
        return rc
    return spawn_override(payload, config, host)


if __name__ == "__main__":
    sys.exit(main())
