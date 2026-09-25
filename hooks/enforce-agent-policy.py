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
when config queue.mergeOnFinish is not true: deny shell commands that merge - `gh pr merge`,
`gh api .../pulls/N/merge` or the mergePullRequest/enablePullRequestAutoMerge mutations, and
`git merge`/`git push` targeting git.defaultBranch (default "main"). The command is split into
simple commands on &&, ||, ;, |, & and parentheses (shlex, so `cd x && gh pr merge` is caught)
and `sh|bash|zsh -c` bodies are parsed recursively. Unreadable config fails closed (deny);
unparseable commands fail open.

Fail-open otherwise: exit 0, no output.

Usage: enforce-agent-policy.py <config_file> <plugin_root> <host>   (payload on stdin)
"""

import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

SPAWN_TOOLS = {"Task", "Agent", "spawn_agent"}
CODEX_TOOL_CLASS = {
    "apply_patch": "Edit",
    "spawn_agent": "Agent", "send_input": "Agent", "wait_agent": "Agent", "close_agent": "Agent",
    "web_search": "WebSearch",
}

SHELL_PUNCT = set("();<>|&")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
GH_MERGE_API = re.compile(r"(^|/)pulls/\d+/merge/?$")
GH_MERGE_MUTATIONS = ("mergePullRequest", "enablePullRequestAutoMerge")
GH_GLOBAL_VALUE_OPTS = {"-R", "--repo", "--hostname"}
PUSH_VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


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


def _segments(command: str):
    """argv of each simple command in a shell string. Chain, pipe and subshell operators split
    commands; redirections (with their fd number and target) are dropped. Raises ValueError on
    unbalanced quotes."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    segs, seg, skip = [], [], False
    for tok in lex:
        if skip:
            skip = False
            continue
        if tok and set(tok) <= SHELL_PUNCT:
            if "<" in tok or ">" in tok:
                if seg and seg[-1].isdigit():
                    seg.pop()
                skip = True
                continue
            if seg:
                segs.append(seg)
            seg = []
            continue
        seg.append(tok)
    if seg:
        segs.append(seg)
    return segs


def _branch(cwd: str) -> str:
    try:
        r = subprocess.run(["git", "-C", cwd, "symbolic-ref", "--short", "-q", "HEAD"],
                           capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip()


def _gh_merges(args) -> bool:
    # Skip gh's own global options (e.g. `gh --repo owner/repo pr merge 123`) so the
    # subcommand check below isn't fooled by an option sitting in args[0]/args[1].
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in GH_GLOBAL_VALUE_OPTS:
            i += 2
        elif any(tok.startswith(o + "=") for o in GH_GLOBAL_VALUE_OPTS):
            i += 1
        elif tok.startswith("-R") and tok != "-R":
            i += 1
        else:
            break
    args = args[i:]
    if args[:2] == ["pr", "merge"]:
        return True
    if args[:1] == ["api"]:
        return any(GH_MERGE_API.search(a) or any(m in a for m in GH_MERGE_MUTATIONS) for a in args[1:])
    return False


def _git_merges(argv, cwd: str, default: str) -> bool:
    """True when a git argv merges into, or pushes to, the default branch."""
    i = 1
    while i < len(argv) and argv[i].startswith("-"):
        if argv[i] in ("-C", "-c") and i + 1 < len(argv):
            if argv[i] == "-C":
                cwd = os.path.join(cwd, os.path.expanduser(argv[i + 1]))
            i += 2
        else:
            i += 1
    sub, args = (argv[i], argv[i + 1:]) if i < len(argv) else ("", [])
    if sub == "merge":
        return (not ({"--abort", "--quit"} & set(args))) and _branch(cwd) == default
    if sub != "push":
        return False
    pos, j = [], 0
    while j < len(args):
        a = args[j]
        if a in ("--all", "--mirror"):
            return True
        if a in PUSH_VALUE_OPTS:
            j += 2
            continue
        if not a.startswith("-"):
            pos.append(a)
        j += 1
    refspecs = pos[1:]
    if not refspecs:
        return "--tags" not in args and _branch(cwd) == default
    for spec in refspecs:
        dst = spec.lstrip("+").rsplit(":", 1)[-1]
        if dst in ("HEAD", "@"):
            dst = _branch(cwd)
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if dst == default:
            return True
    return False


def _merge_action(command: str, cwd: str, default: str, depth: int = 0) -> str:
    """First merge-shaped simple command in a shell string (as text), else ''."""
    for seg in _segments(command):
        k = 0
        while k < len(seg) and ENV_ASSIGN.match(seg[k]):
            k += 1
        argv = seg[k:]
        if not argv:
            continue
        prog = os.path.basename(argv[0])
        if prog == "cd":
            cwd = os.path.join(cwd, os.path.expanduser(argv[1] if len(argv) > 1 else "~"))
        elif prog in ("bash", "sh", "zsh"):
            flags = [n for n, a in enumerate(argv[1:-1], 1)
                     if a.startswith("-") and not a.startswith("--") and "c" in a]
            if flags and depth < 2:
                hit = _merge_action(argv[flags[0] + 1], cwd, default, depth + 1)
                if hit:
                    return hit
        elif (prog == "gh" and _gh_merges(argv[1:])) or (prog == "git" and _git_merges(argv, cwd, default)):
            return " ".join(argv)
    return ""


def merge_deny(payload: dict, config: dict) -> int:
    # ponytail: parses shell text, not a shell - eval, aliases, backticks and scripts that
    # merge internally pass; the skill-level n1_finish_enabled/n1_merge_allowed gates cover those paths.
    run_id = os.environ.get("N1_QUEUE_RUN_ID")
    if not run_id:
        return 0
    if _dict(config.get("queue")).get("mergeOnFinish") is True:
        return 0
    tool_input = _dict(payload.get("tool_input"))
    command = tool_input.get("command") or tool_input.get("cmd")
    if isinstance(command, list):
        command = shlex.join(str(c) for c in command)
    if not isinstance(command, str) or not command:
        return 0
    default = str(_dict(config.get("git")).get("defaultBranch") or "main")
    cwd = str(payload.get("cwd") or os.getcwd())
    try:
        hit = _merge_action(command, cwd, default)
    except ValueError:
        return 0
    if not hit:
        return 0
    sys.stderr.write(f"N1: merge denied in queue run {run_id} -- queue.mergeOnFinish is not true; "
                     f"the ticket stops after PR + CI (blocked: {hit})\n")
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
