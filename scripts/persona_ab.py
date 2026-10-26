#!/usr/bin/env python3
"""Offline paired A/B eval for N1 persona prompts (N1-160).

Runs two versions of one persona prompt (baseline vs candidate) on the fixture
tasks in tests/fixtures/persona-ab/, --runs times each, with both arms shuffled
together, and writes raw.jsonl + summary.json to --out (default
$N1_HOME/scratch/benchmarks/).

What is measured: the persona body (frontmatter stripped) is appended to Claude
Code's default system prompt via --append-system-prompt-file in a `claude -p`
session; the frontmatter `tools:` becomes --tools and `effort:` becomes
--effort. Live N1 dispatches personas as subagents, so absolute numbers differ
from live runs; the A/B delta isolates the persona text because both arms
share everything else.

Isolation: --setting-sources "" --strict-mcp-config (no user settings, hooks,
plugins or MCP servers) and cwd is a throwaway temp git repo. The agent's Bash
tool is NOT sandboxed, so --dangerously-skip-permissions is acceptable only
because the prompts and fixtures are trusted. ~/.claude/CLAUDE.md still loads;
it is identical in both arms, so it adds noise but does not bias the delta.

Makes real, paid claude calls (capped per run by --max-budget-usd). Failed or
timed-out runs are kept as passed=false rows. A row without a session id is
rejected (not written to raw.jsonl), counted in summary.rejected, and the
script exits 2.

Usage:
  python3 scripts/persona_ab.py --persona developer \\
      --baseline agents/developer.md --candidate /tmp/developer-new.md [--runs 3]
"""
import argparse
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIXTURES = REPO / "tests" / "fixtures" / "persona-ab"
PERSONAS = ("developer", "qa-engineer", "code-reviewer")
TOKEN_KEYS = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")
METRICS = TOKEN_KEYS + ("num_turns", "wall_ms", "cost_usd")


def strip_frontmatter(text):
    """Return (frontmatter as {key: value} for simple `key: value` lines, body)."""
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end == -1:
        return {}, text
    meta = {}
    for line in text[4:end].splitlines():
        key, sep, val = line.partition(":")
        if sep:
            meta[key.strip()] = val.strip()
    return meta, text[end + 5:].lstrip("\n")


def tools_arg(meta):
    """Frontmatter `tools: Read, Edit` -> claude --tools value `Read,Edit`."""
    tools = meta.get("tools")
    if not tools:
        return "default"
    return ",".join(t.strip() for t in tools.split(",") if t.strip())


def token_split(data):
    usage = (data or {}).get("usage") or {}
    return {k: int(usage.get(k) or 0) for k in TOKEN_KEYS}


def build_queue(task_names, arms, runs, seed):
    """Every (task, arm, run) once, shuffled so both arms interleave."""
    queue = [(t, a, r) for t in task_names for a in arms for r in range(runs)]
    random.Random(seed).shuffle(queue)
    return queue


def validate_row(row, expected_id):
    """None if the row is acceptable, else the rejection reason."""
    sid = row.get("session_id")
    if not isinstance(sid, str) or not sid:
        return "missing session_id"
    if sid != expected_id:
        return "session_id does not match the harness id"
    if row.get("status") == "ok" and (row.get("raw") or {}).get("session_id") != expected_id:
        return "claude output session_id missing or mismatched"
    return None


def _median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def _metric(row, key):
    return row["tokens"][key] if key in TOKEN_KEYS else row.get(key)


def compute_arm_stats(rows):
    """Per arm: runs, passed, pass_rate (passed/total), medians over passed runs only."""
    stats = {}
    for arm in sorted({r["arm"] for r in rows}):
        arm_rows = [r for r in rows if r["arm"] == arm]
        passed = [r for r in arm_rows if r["passed"]]
        stats[arm] = {"runs": len(arm_rows), "passed": len(passed),
                      "pass_rate": len(passed) / len(arm_rows),
                      "medians": {k: _median([_metric(r, k) for r in passed]) for k in METRICS}}
    return stats


def compute_intersection_stats(rows):
    """Medians per arm restricted to tasks that every arm ran and passed on every run."""
    arms = sorted({r["arm"] for r in rows})

    def clean(task, arm):
        runs = [r for r in rows if r["task"] == task and r["arm"] == arm]
        return bool(runs) and all(r["passed"] for r in runs)

    tasks = [t for t in sorted({r["task"] for r in rows}) if all(clean(t, a) for a in arms)]
    subset = [r for r in rows if r["task"] in tasks]
    return {"tasks": tasks, "arms": {a: s["medians"] for a, s in compute_arm_stats(subset).items()}}


def summarize(rows, rejected, args):
    return {"args": args, "rejected": rejected,
            "arms": compute_arm_stats(rows), "paired": compute_intersection_stats(rows),
            "total_cost_usd": round(sum(r["cost_usd"] for r in rows), 4),
            "tokens_total": {k: sum(r["tokens"][k] for r in rows) for k in TOKEN_KEYS}}


GIT = ["git", "-c", "user.name=persona-ab", "-c", "user.email=persona-ab@localhost",
       "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"]


def load_fixtures(persona, root=FIXTURES, only=None):
    tasks = []
    for d in sorted(p for p in Path(root).iterdir() if (p / "task.json").is_file()):
        spec = json.loads((d / "task.json").read_text(encoding="utf-8"))
        if spec["persona"] == persona and (only is None or d.name == only):
            tasks.append({"name": d.name, "dir": d, "prompt": spec["prompt"]})
    return tasks


def prepare_repo(task_dir, dest):
    """Copy the fixture repo to dest and commit it so checks can diff against HEAD."""
    shutil.copytree(str(Path(task_dir) / "repo"), str(dest), ignore=shutil.ignore_patterns("__pycache__"))
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "fixture"]):
        subprocess.run(GIT + cmd, cwd=dest, check=True, capture_output=True)


def run_check(check, repo, timeout=120):
    try:
        return subprocess.run(["bash", str(check), str(repo)], capture_output=True,
                              timeout=timeout).returncode == 0
    except subprocess.TimeoutExpired:
        return False
