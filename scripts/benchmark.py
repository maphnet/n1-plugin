#!/usr/bin/env python3
"""N1 orchestrator benchmark.

Measures, per N1 version, how many human interventions a pipeline run needed,
plus telemetry-derived quality metrics. Persists per-run caches, snapshots,
and reports under an output directory (default ~/.n1/benchmark/).

Usage:
  python3 scripts/benchmark.py collect  [--n1-root DIR] [--projects-dir DIR] [--out DIR] [--since YYYY-MM-DD] [--force] [--ambiguous-out FILE]
  python3 scripts/benchmark.py finalize --labels FILE [--out DIR] [--by version|week] [--plugin-version V] [--judge-model M]
  python3 scripts/benchmark.py report   [--out DIR] [--snapshot ID] [--by version|week]
  python3 scripts/benchmark.py baseline set <version> | show [--out DIR]

The script never calls a model. Ambiguous turns are printed by `collect`;
the n1-benchmark skill labels them and passes the labels file to `finalize`.
Read-only with respect to ~/.n1/<project>/ and ~/.claude/projects/.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import statistics
import sys
from pathlib import Path

RUBRIC_VERSION = 1
DEFAULT_JUDGE_MODEL = "claude-haiku-4-5-20251001"
ELIGIBLE_OUTCOMES = {"pr_created", "pr_skipped", "investigation_complete"}
MIN_SAMPLE = 5
TEXT_LIMIT = 600
LABELS = {"answer", "approval", "correction", "instruction", "noise"}
FALLBACK_LABEL = "instruction"


# ---------------------------------------------------------------- run loading

def parse_ts(value):
    """ISO-8601 UTC timestamp -> epoch seconds, or None."""
    if not value or not isinstance(value, str):
        return None
    base = value.split(".")[0].rstrip("Z")
    try:
        return dt.datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc).timestamp()
    except ValueError:
        return None


def read_jsonl(path: Path):
    """Yield (record, None) for parseable lines and (None, line) for malformed ones."""
    try:
        text = Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line), None
        except json.JSONDecodeError:
            yield None, line


def load_runs(n1_root: Path):
    """Load merged run records from <n1_root>/*/memory/*/telemetry/runs/*.jsonl.

    Returns (runs, malformed_line_count). Dedupes by run_id keeping the last line.
    """
    n1_root = Path(n1_root)
    by_id = {}
    malformed = 0
    if not n1_root.is_dir():
        return [], 0
    for path in sorted(n1_root.glob("*/memory/*/telemetry/runs/*.jsonl")):
        for rec, bad in read_jsonl(path):
            if bad is not None:
                malformed += 1
                continue
            if not isinstance(rec, dict) or "schema_version" not in rec or not rec.get("run_id"):
                continue
            rec["_source_path"] = str(path)
            by_id[rec["run_id"]] = rec
    return list(by_id.values()), malformed


def is_eligible(run: dict) -> bool:
    return run.get("final_outcome") in ELIGIBLE_OUTCOMES


# --------------------------------------------------------------- linking

def raw_agents_session_path(run: dict):
    """First session_transcript_path in the run's raw agents file, if that file exists."""
    src = run.get("_source_path")
    if not src:
        return None
    raw = Path(src).parent.parent / "raw" / "agents" / f"{run['run_id']}.jsonl"
    if not raw.is_file():
        return None
    for rec, _ in read_jsonl(raw):
        if rec and rec.get("session_transcript_path"):
            return rec["session_transcript_path"]
    return None


def candidate_project_dirs(projects_dir: Path, project: str, branch):
    """Claude Code project dirs whose slug ends with the project name, or is a
    worktree slug for it (…--claude-worktrees-<project>-<branch> or …--claude-worktrees-<branch>)."""
    projects_dir = Path(projects_dir)
    if not projects_dir.is_dir() or not project:
        return []
    proj = project.lower()
    tails = {f"-{proj}"}
    if branch:
        b = str(branch).lower()
        tails.add(f"-{proj}--claude-worktrees-{proj}-{b}")
        tails.add(f"-{proj}--claude-worktrees-{b}")
    out = []
    for d in sorted(projects_dir.iterdir()):
        if not d.is_dir():
            continue
        name = d.name.lower()
        if any(name.endswith(t) for t in tails):
            out.append(d)
    return out


def is_human_turn(rec: dict) -> bool:
    """A user record typed by the human: not meta, not a tool result, not a
    slash-command expansion, not an interrupt marker."""
    if not isinstance(rec, dict) or rec.get("type") != "user" or rec.get("isMeta"):
        return False
    origin = rec.get("origin")
    if isinstance(origin, dict) and origin.get("kind") not in (None, "human"):
        return False
    text = turn_text(rec)
    if text is None:
        return False
    stripped = text.lstrip()
    if stripped.startswith("<command-") or stripped.startswith("[Request interrupted"):
        return False
    return True


def turn_text(rec: dict):
    """Concatenated text of a user record, or None if it carries no text (tool results)."""
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        if parts:
            return "\n".join(parts)
    return None


def human_turn_timestamps(path: Path):
    out = []
    for rec, _ in read_jsonl(path):
        if rec and is_human_turn(rec):
            ts = parse_ts(rec.get("timestamp"))
            if ts is not None:
                out.append(ts)
    return out


def _transcript_mentions(path: Path, needle: str) -> bool:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return any(needle in line for line in fh)
    except OSError:
        return False


def link_transcript(run: dict, projects_dir: Path):
    """Return (transcript_path, method). method: agent_event | heuristic | unlinked."""
    direct = raw_agents_session_path(run)
    if direct and Path(direct).is_file():
        return direct, "agent_event"

    start, end = parse_ts(run.get("started_at")), parse_ts(run.get("completed_at"))
    ticket = run.get("ticket_id") or ""
    if start is None or end is None or not ticket:
        return None, "unlinked"

    best, best_count = None, 0
    for d in candidate_project_dirs(projects_dir, run.get("project") or "", run.get("branch")):
        for path in sorted(d.glob("*.jsonl")):
            in_window = sum(1 for ts in human_turn_timestamps(path) if start <= ts <= end)
            if in_window == 0 or not _transcript_mentions(path, ticket):
                continue
            if in_window > best_count:
                best, best_count = str(path), in_window
    if best:
        return best, "heuristic"
    return None, "unlinked"


# ------------------------------------------------------------------------ CLI

def build_parser():
    p = argparse.ArgumentParser(prog="benchmark.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--out", default=os.path.expanduser("~/.n1/benchmark"))

    c = sub.add_parser("collect")
    common(c)
    c.add_argument("--n1-root", default=os.path.expanduser("~/.n1"))
    c.add_argument("--projects-dir", default=os.path.expanduser("~/.claude/projects"))
    c.add_argument("--since", default=None, help="YYYY-MM-DD; ignore runs started earlier")
    c.add_argument("--force", action="store_true", help="re-process cached runs")
    c.add_argument("--ambiguous-out", default=None, help="write ambiguous turns JSON here instead of stdout")

    f = sub.add_parser("finalize")
    common(f)
    f.add_argument("--labels", required=True)
    f.add_argument("--by", choices=["version", "week"], default="version")
    f.add_argument("--plugin-version", default=None)
    f.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)

    r = sub.add_parser("report")
    common(r)
    r.add_argument("--snapshot", default=None, help="snapshot id; default latest")
    r.add_argument("--by", choices=["version", "week"], default="version")

    b = sub.add_parser("baseline")
    common(b)
    b.add_argument("action", choices=["set", "show"])
    b.add_argument("version", nargs="?")
    return p


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    handler = COMMANDS.get(args.cmd)
    if handler is None:
        print(f"unknown command: {args.cmd}", file=sys.stderr)
        return 2
    return handler(args)


COMMANDS = {}

if __name__ == "__main__":
    sys.exit(main())
