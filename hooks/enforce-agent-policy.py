#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy, identical on Claude Code and Codex.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>` on Claude, `n1-<p>` on Codex) and the persona's frontmatter has a `tools:` list:
deny any tool outside it. On Claude this duplicates native enforcement; on Codex it is the
only enforcement. Codex has no per-capability tools, so its tools map onto the classes
personas declare (CODEX_TOOL_CLASS); unmapped Codex tools (shell, update_plan, MCP) pass,
and read-only personas rely on sandbox_mode = "read-only" in their generated TOML.
Denial: exit 2, reason on stderr.

Case 2 - Claude spawn model override. For Claude spawn tools targeting an N1 persona,
rewrite `model` from config `models.<persona>` (string = Claude only; object keyed by
host). Codex model/effort pairs are authoritative from `n1_resolve_agent`; the hook
never independently rewrites them, so it cannot reintroduce a rejected Astra override.

Case 3 - queue merge gate (NP-212). Only in queue children (env N1_QUEUE_RUN_ID set) and only
when config queue.mergeOnFinish is not true: deny Bash commands whose raw text names a merge
action - `gh ... pr ... merge`, `gh ... api ...` mentioning merge/mergePullRequest/
enablePullRequestAutoMerge, `git ... merge`, or `git ... push` naming git.defaultBranch (default
"main"). This is a plain case-insensitive text scan over the whole command string, not a shell
parser: three review cycles of increasingly precise shlex-based tokenizing (heredocs, comments,
wrapper commands, shell keywords, redirects) kept opening new bypasses as fast as they closed old
ones. A raw scan can't be evaded the same way chained/obfuscated shell syntax evaded a parser, and
over-blocking inside a queue child (a merge-shaped string inside unrelated text, e.g. prose that
quotes a push command) is an accepted trade-off - the ticket's AC prioritizes "cannot merge even
if the model tries" over precision. Known gap: it does not resolve the current branch, so a bare
`git push`/`git merge` that never names a branch in the command text is not caught - the
skill-level n1_finish_enabled/n1_merge_allowed gates are the primary control for that shape, this
hook is the backstop for the common case (the model naming the branch or PR explicitly).
Unreadable config fails closed (deny).

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root> <host>   (payload on stdin)
"""

import json
import os
import re
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}
CODEX_TOOL_CLASS = {
    "apply_patch": "Edit",
    "spawn_agent": "Agent", "send_input": "Agent", "wait_agent": "Agent", "close_agent": "Agent",
    "web_search": "WebSearch",
}

# Raw case-insensitive text scan (see Case 3 docstring above for why this replaced a shlex
# parser). `\b` word boundaries keep "github"/"digit"/"mergeCommit" from matching.
MERGE_RE = re.compile(
    r"\bgh\b.*\bpr\b.*\bmerge\b"
    r"|\bgh\b.*\bapi\b.*\b(?:merge|mergepullrequest|enablepullrequestautomerge)\b"
    r"|\bgit\b.*\bmerge\b",
    re.I | re.S,
)
PUSH_RE = re.compile(r"\bgit\b.*\bpush\b", re.I | re.S)


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
    # Codex dispatch must preserve the model selected by n1_resolve_agent. In
    # particular, a configured Astra override can be rejected by its contextual
    # eligibility policy and must not be injected again here.
    if host == "codex":
        return 0
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


def _dict(value):
    return value if isinstance(value, dict) else {}


def merge_deny(payload: dict, config: dict) -> int:
    # ponytail: a raw case-insensitive text scan over the whole command string, not a shell
    # parser -- see the Case 3 docstring above for why. Over-blocking (a merge-shaped string
    # inside unrelated text) is accepted by design; under-blocking a bare `git push`/`git merge`
    # that never names a branch is a known, documented gap the skill-level gates cover instead.
    run_id = os.environ.get("N1_QUEUE_RUN_ID")
    if not run_id:
        return 0
    if _dict(config.get("queue")).get("mergeOnFinish") is True:
        return 0
    tool_input = _dict(payload.get("tool_input"))
    command = tool_input.get("command") or tool_input.get("cmd")
    if isinstance(command, list):
        command = " ".join(str(c) for c in command)
    if not isinstance(command, str) or not command:
        return 0
    default = str(_dict(config.get("git")).get("defaultBranch") or "main")
    hit = MERGE_RE.search(command) or (
        PUSH_RE.search(command) and re.search(r"\b%s\b" % re.escape(default), command)
    )
    if not hit:
        return 0
    sys.stderr.write(f"N1: merge denied in queue run {run_id} -- queue.mergeOnFinish is not true; "
                     f"the ticket stops after PR + CI\n")
    return 2


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
    if not isinstance(config, dict):
        config = {}
    rc = restriction(payload, plugin_root, host)
    if rc:
        return rc
    rc = merge_deny(payload, config)
    if rc:
        return rc
    return spawn_override(payload, config, host)


if __name__ == "__main__":
    sys.exit(main())
