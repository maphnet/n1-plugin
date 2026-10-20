#!/usr/bin/env python3
"""PreToolUse hook: N1 agent policy.

Case 1 - persona tool restriction. The payload's `agent_type` names an N1 persona
(`n1:<p>`) and the persona's frontmatter has a `tools:` list: deny any tool outside it.
This duplicates native enforcement as a backstop. Denial: exit 2, reason on stderr.

Case 2 - spawn model override. For spawn tools targeting an N1 persona, rewrite `model`
from config `models.<persona>` (string, or a legacy host-keyed object read through its
"claude-code" key).

Case 3 - queue merge deny (N1-114). Unconditional, no config gate: only in headless queue children
(env N1_QUEUE_RUN_ID set and N1_HEADLESS=1), deny Bash `gh pr merge`, `gh api` calls naming
mergePullRequest/enablePullRequestAutoMerge/pulls/<n>/merge, and `git push` targeting
git.defaultBranch (default "main"): a refspec `[refs/heads/]<default>` or `<src>:<default>`,
`--all`/`--mirror`, or a bare/HEAD push while the payload cwd is on the default branch. `git merge`
is NOT denied (N1-45). Quotes/backslashes are stripped first (bash does the same, so
`g''h pr m''erge` is caught), then the command is split into simple commands and tokenized -
linear in command length (SEC-22). Known gaps: runtime string-building (eval, base64, variables,
aliases) and a bare push after `cd` into another checkout on the default branch.

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root>   (payload on stdin)
"""

import functools
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}
SEGMENT_RE = re.compile(r"[;&|\n()`{}<>]")
MERGE_API_RE = re.compile(r"mergepullrequest|enablepullrequestautomerge|/pulls/[^/\s]+/merge\b", re.I)
GH_VALUE_FLAGS = {"-R", "--repo"}
GIT_VALUE_FLAGS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
PUSH_VALUE_FLAGS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


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


def _positionals(tokens, value_flags):
    """(positional, flag-value) pairs: tokens not starting with '-', skipping values of value_flags."""
    out, skip, cwd = [], False, None
    for i, tok in enumerate(tokens):
        if skip:
            skip = False
        elif tok in value_flags:
            skip = True
            if tok == "-C" and i + 1 < len(tokens):
                cwd = tokens[i + 1]
        elif not tok.startswith("-"):
            out.append(tok)
    return out, cwd


@functools.lru_cache(maxsize=None)
def _current_branch(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() or None


def _is_merge(tokens, api_hit, default, cwd):
    """One simple command starting at a gh/git token (ends before the next gh/git token)."""
    pos, git_cwd = _positionals(tokens[1:], GH_VALUE_FLAGS if tokens[0] == "gh" else GIT_VALUE_FLAGS)
    if tokens[0] == "gh":
        return pos[:2] == ["pr", "merge"] or (pos[:1] == ["api"] and api_hit)
    if pos[:1] != ["push"]:
        return False
    args = tokens[tokens.index("push") + 1:]
    if "--all" in args or "--mirror" in args:
        return True
    refs, _ = _positionals(args, PUSH_VALUE_FLAGS)
    target = re.compile(r"(?:^|:)(?:refs/heads/)?%s$" % re.escape(default), re.I)
    if any(target.search(r.lstrip("+")) for r in refs[1:]):
        return True
    if not all(r in ("HEAD", "@") for r in refs[1:]):
        return False
    base = cwd or os.getcwd()
    branch = _current_branch(os.path.join(base, git_cwd) if git_cwd else base)
    return bool(branch) and branch.lower() == default.lower()


def _commands(command):
    """Token lists, one per gh/git invocation; each token is visited once (linear, SEC-22)."""
    for segment in SEGMENT_RE.split(command):
        chunk = None
        for tok in segment.split():
            name = tok.rsplit("/", 1)[-1]
            if name in ("gh", "git"):
                if chunk:
                    yield chunk
                chunk = [name]
            elif chunk is not None:
                chunk.append(tok)
        if chunk:
            yield chunk


def merge_deny(payload: dict, config: dict) -> int:
    run_id = os.environ.get("N1_QUEUE_RUN_ID")
    if not run_id or os.environ.get("N1_HEADLESS") != "1":
        return 0
    tool_input = payload.get("tool_input")
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    command = tool_input.get("command") or tool_input.get("cmd")
    if isinstance(command, list):
        command = " ".join(str(c) for c in command)
    if not isinstance(command, str) or not command:
        return 0
    command = re.sub(r"[\"'\\]", "", command)
    git_cfg = config.get("git")
    default = str((git_cfg if isinstance(git_cfg, dict) else {}).get("defaultBranch") or "main")
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
    api_hit = MERGE_API_RE.search(command) is not None
    if not any(_is_merge(c, api_hit, default, cwd) for c in _commands(command)):
        return 0
    sys.stderr.write(f"N1: merge denied in queue run {run_id} -- N1 never merges; "
                     f"the ticket stops after PR + CI and a human merges\n")
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
    rc = restriction(payload, plugin_root) or merge_deny(payload, config)
    if rc:
        return rc
    return spawn_override(payload, config)


if __name__ == "__main__":
    sys.exit(main())
