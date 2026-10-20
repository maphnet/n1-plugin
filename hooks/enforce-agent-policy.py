#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>`) and the persona's frontmatter has a `tools:` list: deny any tool outside it.
This duplicates native enforcement as a backstop. Denial: exit 2, reason on stderr.

Case 2 - spawn model override. For spawn tools targeting an N1 persona, rewrite `model`
from config `models.<persona>` (string, or a legacy host-keyed object read through its
"claude-code" key).

Case 3 - queue merge gate (NP-212). Only in queue children (env N1_QUEUE_RUN_ID set) and only
when config queue.mergeOnFinish is not true: deny Bash commands whose raw text names a merge
action - `gh ... pr ... merge`, `gh ... api ...` mentioning merge/mergePullRequest/
enablePullRequestAutoMerge, `git ... merge`, or `git ... push` naming git.defaultBranch (default
"main"). This is a plain case-insensitive text scan over the whole command string (quotes and
backslashes stripped first, the same way bash strips them before running the command, so
`g''h pr m''erge` can't hide the words), not a shell parser: three review cycles of increasingly
precise shlex-based tokenizing (heredocs, comments, wrapper commands, shell keywords, redirects)
kept opening new bypasses as fast as they closed old ones. A raw scan isn't evaded by
chained/obfuscated *static* shell syntax the way a parser was, and over-blocking inside a queue
child (a merge-shaped string inside unrelated text, e.g. prose that quotes a push command) is an
accepted trade-off - the ticket's AC prioritizes "cannot merge even
if the model tries" over precision. Known gap: it does not resolve the current branch, so a bare
`git push` that never names the default branch in the command text is not caught (any `git ...
merge` is denied outright regardless of a named branch - only the push check has this
precondition) - the skill-level n1_merge_allowed gate is the primary control
for that shape, this hook is the backstop for the common case (the model naming the branch or PR
explicitly). Also does not catch a command whose merge/push words only exist after shell-side
runtime string-building (base64, `eval`, variable/command substitution, git/gh aliases) -- no text
scan can see those without executing them; that class is an accepted, documented limit, not a
target for this hook. Unreadable config fails closed (deny).

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root>   (payload on stdin)
"""

import json
import os
import re
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}

# Raw case-insensitive text scan (see Case 3 docstring above for why this replaced a shlex
# parser). `\b` word boundaries keep "github"/"digit"/"mergeCommit" from matching. Independent
# per-word checks (not a single chained `\bgh\b.*\bpr\b.*\bmerge\b` pattern) -- Python's regex
# engine doesn't memoize, so two greedy `.*` under re.S is quadratic-ish and denial-of-service-able
# on a long, repetitive command (SEC-22); this stays linear in command length.
MERGE_API_RE = re.compile(r"\b(?:merge|mergepullrequest|enablepullrequestautomerge)\b", re.I)


def _has(command: str, word_re: str) -> bool:
    return re.search(word_re, command, re.I) is not None


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
    # Bash strips quotes/backslashes before a command runs; the scan must too, or
    # `g''h pr m''erge 12` slips through with none of "gh"/"pr"/"merge" intact as words (SEC-21).
    command = re.sub(r"[\"'\\]", "", command)
    default = str(_dict(config.get("git")).get("defaultBranch") or "main")
    is_merge = (
        (_has(command, r"\bgh\b") and _has(command, r"\bpr\b") and _has(command, r"\bmerge\b"))
        or (_has(command, r"\bgh\b") and _has(command, r"\bapi\b") and MERGE_API_RE.search(command))
        or (_has(command, r"\bgit\b") and _has(command, r"\bmerge\b"))
    )
    is_push_to_default = (
        _has(command, r"\bgit\b") and _has(command, r"\bpush\b")
        and _has(command, r"\b%s\b" % re.escape(default))
    )
    if not (is_merge or is_push_to_default):
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
    rc = merge_deny(payload, config)
    if rc:
        return rc
    return spawn_override(payload, config)


if __name__ == "__main__":
    sys.exit(main())
