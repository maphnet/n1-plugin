#!/usr/bin/env python3
"""Audit Claude Code transcripts of /n1:n1-start sessions for work done in the
orchestrator (main thread) that N1 delegates to subagents.

Usage:
  python3 scripts/audit-orchestrator.py [--since YYYY-MM-DD] [--projects-dir DIR] [FILE.jsonl ...]

With no FILE args, scans DIR (default ~/.claude/projects) for sessions whose
first user turn invoked /n1:n1-start. Read-only; exit code is always 0.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

NOISE_PATH = re.compile(r"/\.n1/|/plugins/cache/|/\.claude/(?!worktrees/)|/memory/|/scratchpad/|/tasks/")
TEST_CMD = re.compile(
    r"\b(pytest|npm (test|run)|pnpm|yarn|go test|cargo (test|build)|make (test|check|install)|"
    r"docker( compose)?|curl|pip3? install|uv (pip|venv|run)|python3? -m (pytest|black|flake8|mypy)|"
    r"ruff|eslint|tsc|black|flake8|mypy|git commit|git add|git push)\b"
)
NOISE_CMD = re.compile(r"telemetry\.sh|signals\.sh|config\.sh|frontmatter\.sh|memory\.sh|n1_")
FORBIDDEN_CTX = re.compile(
    r"^(after AGENT (n1:qa-engineer|n1:code-reviewer|n1:security-reviewer|n1:local-test-planner|"
    r"n1:developer|n1:tech-writer)|in SKILL (n1:n1-ci|n1:n1-pr|superpowers:brainstorming))"
)


def is_n1_start(path, max_lines=40):
    try:
        with open(path, encoding="utf-8") as fh:
            for i, line in enumerate(fh):
                if i > max_lines:
                    return False
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") != "user":
                    continue
                c = d.get("message", {}).get("content")
                s = c if isinstance(c, str) else json.dumps(c)
                if "<command-name>/n1:n1-start" in s or "<command-name>/n1-start" in s:
                    return True
    except OSError:
        return False
    return False


def analyze(path):
    ctx = "start"
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("isSidechain"):
                continue
            if d.get("type") != "assistant":
                continue
            for c in d.get("message", {}).get("content", []) or []:
                if not (isinstance(c, dict) and c.get("type") == "tool_use"):
                    continue
                name, inp = c.get("name"), c.get("input", {}) or {}
                if name == "Agent":
                    ctx = "after AGENT " + str(inp.get("subagent_type", "?"))
                    rows.append(("", "CTX", ctx, ""))
                elif name == "Skill":
                    ctx = "in SKILL " + str(inp.get("skill"))
                    rows.append(("", "CTX", ctx, ""))
                elif name in ("Read", "Edit", "Write", "MultiEdit"):
                    p = inp.get("file_path", "")
                    if not NOISE_PATH.search(p):
                        kind = "R" if name == "Read" else "W"
                        flag = "!!" if (kind == "W" or FORBIDDEN_CTX.match(ctx)) else "  "
                        rows.append((flag, kind, ctx, p))
                elif name in ("Grep", "Glob"):
                    flag = "!!" if FORBIDDEN_CTX.match(ctx) else "  "
                    rows.append((flag, "S", ctx, f"{name} {inp.get('pattern', '')} @{inp.get('path', '')}"))
                elif name == "Bash":
                    cmd = (inp.get("command") or "").replace("\n", " ")
                    if NOISE_CMD.search(cmd) and not TEST_CMD.search(cmd):
                        continue
                    if TEST_CMD.search(cmd):
                        flag = "!!" if FORBIDDEN_CTX.match(ctx) or re.search(r"\bgit (commit|add)\b", cmd) else "  "
                        rows.append((flag, "B", ctx, cmd[:140]))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--since", default=None)
    ap.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    a = ap.parse_args()

    files = a.files
    if not files:
        since = dt.datetime.strptime(a.since, "%Y-%m-%d").timestamp() if a.since else 0
        cands = [f for f in glob.glob(os.path.join(a.projects_dir, "*", "*.jsonl")) if os.path.getmtime(f) >= since]
        files = sorted((f for f in cands if is_n1_start(f)), key=os.path.getmtime, reverse=True)

    total = 0
    for f in files:
        rows = analyze(f)
        viol = sum(1 for r in rows if r[0] == "!!")
        total += viol
        print(f"===== {f}  (violations: {viol})")
        for flag, kind, ctx, text in rows:
            if kind == "CTX":
                print(f"   -- {ctx}")
            else:
                print(f"{flag} {kind}  {text}")
    print(f"TOTAL sessions: {len(files)}  violations: {total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
