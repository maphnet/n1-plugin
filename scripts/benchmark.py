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


# ------------------------------------------------------- turn extraction

def step_at(run: dict, ts: float) -> str:
    for step in run.get("steps") or []:
        s, e = parse_ts(step.get("started_at")), parse_ts(step.get("completed_at"))
        if s is not None and e is not None and s <= ts <= e:
            return step.get("step") or "outside"
    return "outside"


def _assistant_text_and_ask(rec: dict):
    content = (rec.get("message") or {}).get("content")
    if not isinstance(content, list):
        return (content if isinstance(content, str) else ""), False
    texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
    last = content[-1] if content else None
    asked = isinstance(last, dict) and last.get("type") == "tool_use" and last.get("name") == "AskUserQuestion"
    return "\n".join(texts), asked


def extract_turns(transcript_path: str, run: dict):
    turns = []
    prev_text, prev_ask = "", False
    n = 0
    for rec, _ in read_jsonl(Path(transcript_path)):
        if not rec:
            continue
        if rec.get("type") == "assistant" and not rec.get("isSidechain"):
            prev_text, prev_ask = _assistant_text_and_ask(rec)
            continue
        if not is_human_turn(rec):
            continue
        ts = parse_ts(rec.get("timestamp"))
        turns.append({
            "id": f"{run['run_id']}#{n}",
            "timestamp": rec.get("timestamp"),
            "step": step_at(run, ts) if ts is not None else "outside",
            "text": (turn_text(rec) or "")[:TEXT_LIMIT],
            "prev_assistant": prev_text[:TEXT_LIMIT],
            "asked_question": prev_ask,
        })
        n += 1
        prev_text, prev_ask = "", False
    return turns


COMMANDS = {}


# ------------------------------------------------- heuristic classification

APPROVAL_VOCAB = frozenset({
    "yes", "y", "ok", "okay", "go", "continue", "proceed", "approved", "approve",
    "lgtm", "looks good", "do it", "sure", "fine", "yep", "yup",
    "1", "2", "3", "4", "5", "6", "7", "8", "9",
})
ANSWER_MAX_CHARS = 200


def _normalize(text: str) -> str:
    return "".join(ch for ch in text.lower() if ch.isalnum() or ch.isspace()).strip()


def classify_heuristic(turn: dict) -> str:
    text = turn.get("text") or ""
    if not text.strip():
        return "noise"
    prev = (turn.get("prev_assistant") or "").rstrip()
    asked = bool(turn.get("asked_question")) or prev.endswith("?")
    if asked and len(text) < ANSWER_MAX_CHARS:
        return "answer"
    if _normalize(text) in APPROVAL_VOCAB:
        return "approval"
    return "ambiguous"


# --------------------------------------------------------------- run cache

def run_cache_path(out: Path, run_id: str) -> Path:
    return Path(out) / "runs" / f"{run_id}.json"


def load_cache(out: Path):
    caches = {}
    for p in sorted((Path(out) / "runs").glob("*.json")):
        try:
            c = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if c.get("run_id"):
            caches[c["run_id"]] = c
    return caches


def save_cache(out: Path, cache: dict):
    p = run_cache_path(out, cache["run_id"])
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(cache, indent=1, sort_keys=True), encoding="utf-8")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_run_cache(run: dict, projects_dir: Path) -> dict:
    eligible = is_eligible(run)
    cache = {
        "run_id": run["run_id"], "n1_version": run.get("n1_version") or "",
        "project": run.get("project"), "ticket_id": run.get("ticket_id"),
        "started_at": run.get("started_at"), "completed_at": run.get("completed_at"),
        "final_outcome": run.get("final_outcome"), "eligible": eligible,
        "link_method": "skipped", "transcript_path": None, "turns": [],
        "metrics": {}, "per_step": {}, "judge_model": None,
        "rubric_version": RUBRIC_VERSION, "judge_fallbacks": 0, "collected_at": now_iso(),
        "_run": run,
    }
    if not eligible:
        return cache
    path, method = link_transcript(run, projects_dir)
    cache["link_method"], cache["transcript_path"] = method, path
    if path:
        for t in extract_turns(path, run):
            label = classify_heuristic(t)
            t["label"] = label
            t["label_source"] = "heuristic" if label != "ambiguous" else None
            t["reason"] = None
            cache["turns"].append(t)
    return cache


def _strip_private(cache: dict) -> dict:
    return {k: v for k, v in cache.items() if not k.startswith("_")}


def cmd_collect(args) -> int:
    out = Path(args.out)
    runs, malformed = load_runs(Path(args.n1_root))
    since = parse_ts(f"{args.since}T00:00:00Z") if args.since else None
    if since is not None:
        runs = [r for r in runs if (parse_ts(r.get("started_at")) or 0) >= since]
    existing = {} if args.force else load_cache(out)
    new, cached, ambiguous = 0, 0, []
    for run in runs:
        cache = existing.get(run["run_id"])
        if cache is None:
            cache = build_run_cache(run, Path(args.projects_dir))
            cache["run_record"] = {k: v for k, v in run.items() if not k.startswith("_")}
            save_cache(out, _strip_private(cache))
            new += 1
        else:
            cached += 1
        for t in cache["turns"]:
            if t.get("label") == "ambiguous":
                ambiguous.append({"id": t["id"], "text": t["text"], "prev_assistant": t["prev_assistant"]})
    result = {"ambiguous": ambiguous, "runs_new": new, "runs_cached": cached,
              "runs_total": len(runs), "malformed_lines": malformed}
    payload = json.dumps(result, indent=1)
    if args.ambiguous_out:
        Path(args.ambiguous_out).write_text(payload, encoding="utf-8")
        print(f"runs: {len(runs)} (new {new}, cached {cached}); ambiguous turns: {len(ambiguous)} -> {args.ambiguous_out}")
    else:
        print(payload)
    return 0


COMMANDS["collect"] = cmd_collect


# ------------------------------------------------------------------ metrics

class Metric:
    name = ""
    unit = ""
    direction = "lower"  # or "higher"

    def compute(self, run_record: dict, turns):
        raise NotImplementedError


class TurnCountMetric(Metric):
    unit = "count"

    def __init__(self, name, labels):
        self.name, self.labels = name, set(labels)

    def compute(self, run_record, turns):
        if turns is None:
            return None
        return float(sum(1 for t in turns if t.get("label") in self.labels))


def _last_outcomes(run_record: dict):
    events = run_record.get("outcomes") or []
    for ev in reversed(events):
        if isinstance(ev, dict) and isinstance(ev.get("outcomes"), dict):
            return ev["outcomes"]
    return {}


class OutcomeMetric(Metric):
    def __init__(self, name, key, unit, direction, boolean=False):
        self.name, self.key, self.unit, self.direction, self.boolean = name, key, unit, direction, boolean

    def compute(self, run_record, turns):
        raw = _last_outcomes(run_record).get(self.key)
        if raw is None or raw == "":
            return None
        if self.boolean:
            return 1.0 if str(raw).lower() == "true" else 0.0
        try:
            return float(raw)
        except (TypeError, ValueError):
            return None


class DurationMetric(Metric):
    name, unit, direction = "duration_min", "minutes", "lower"

    def compute(self, run_record, turns):
        s, e = parse_ts(run_record.get("started_at")), parse_ts(run_record.get("completed_at"))
        if s is None or e is None or e < s:
            return None
        return round((e - s) / 60.0, 1)


class OrchestratorTokensMetric(Metric):
    name, unit, direction = "orchestrator_output_tokens", "tokens", "lower"

    def compute(self, run_record, turns):
        orch = run_record.get("orchestrator") or {}
        val = (orch.get("totals") or {}).get("output_tokens")
        return float(val) if isinstance(val, (int, float)) else None


class CompactionsMetric(Metric):
    name, unit, direction = "compactions", "count", "lower"

    def compute(self, run_record, turns):
        val = (run_record.get("summary") or {}).get("compaction_count")
        return float(val) if isinstance(val, (int, float)) else None


METRICS = [
    TurnCountMetric("interventions", {"answer", "correction"}),
    TurnCountMetric("answers", {"answer"}),
    TurnCountMetric("corrections", {"correction"}),
    OutcomeMetric("fix_cycles", "fix_cycles_count", "count", "lower"),
    OutcomeMetric("review_pass_first_try", "review_pass_first_try", "ratio", "higher", boolean=True),
    DurationMetric(),
    OrchestratorTokensMetric(),
    CompactionsMetric(),
]
TURN_METRICS = [m for m in METRICS if isinstance(m, TurnCountMetric)]


def compute_run_metrics(cache: dict) -> None:
    run_record = cache.get("run_record") or {}
    turns = cache.get("turns") or []
    linked = cache.get("link_method", "heuristic") in ("agent_event", "heuristic")
    turn_arg = turns if linked else None
    cache["metrics"] = {m.name: m.compute(run_record, turn_arg) for m in METRICS}
    per_step = {}
    if linked:
        for step in sorted({t.get("step") or "outside" for t in turns}):
            subset = [t for t in turns if (t.get("step") or "outside") == step]
            per_step[step] = {m.name: m.compute(run_record, subset) for m in TURN_METRICS}
    cache["per_step"] = per_step


def apply_labels(cache: dict, labels: dict) -> int:
    """Merge judge labels into ambiguous turns. Returns the number of fallbacks."""
    fallbacks = 0
    for t in cache.get("turns") or []:
        if t.get("label") != "ambiguous":
            continue
        entry = labels.get(t["id"]) or {}
        label = entry.get("label")
        if label in LABELS:
            t["label"], t["label_source"], t["reason"] = label, "judge", entry.get("reason")
        else:
            t["label"], t["label_source"], t["reason"] = FALLBACK_LABEL, "fallback", None
            fallbacks += 1
    return fallbacks


# -------------------------------------------------------------- aggregation

def version_key(v: str):
    parts = []
    for piece in (v or "").split("."):
        try:
            parts.append((1, int(piece)))
        except ValueError:
            parts.append((0, piece))
    return (1 if parts and parts[0][0] == 1 else 0, parts)


def group_key(cache: dict, by: str) -> str:
    if by == "week":
        ts = parse_ts(cache.get("started_at"))
        if ts is None:
            return "unknown"
        iso = dt.datetime.fromtimestamp(ts, dt.timezone.utc).isocalendar()
        return f"{iso[0]}-W{iso[1]:02d}"
    return cache.get("n1_version") or "unknown"


def bootstrap_ci(values, seed=0, n=1000, alpha=0.05):
    vals = [float(v) for v in values]
    if not vals:
        return (0.0, 0.0)
    if len(vals) == 1:
        return (vals[0], vals[0])
    rng = random.Random(seed)
    means = sorted(statistics.fmean(rng.choices(vals, k=len(vals))) for _ in range(n))
    lo = means[int(alpha / 2 * n)]
    hi = means[min(n - 1, int((1 - alpha / 2) * n))]
    return (round(lo, 3), round(hi, 3))


def aggregate(caches, by: str) -> dict:
    groups = {}
    for c in caches:
        groups.setdefault(group_key(c, by), []).append(c)
    out = {}
    for key, members in groups.items():
        eligible = [c for c in members if c.get("eligible")]
        metrics = {}
        for m in METRICS:
            vals = [c["metrics"].get(m.name) for c in eligible]
            vals = [v for v in vals if isinstance(v, (int, float))]
            if not vals:
                metrics[m.name] = None
                continue
            metrics[m.name] = {"n": len(vals), "mean": round(statistics.fmean(vals), 3),
                               "median": round(statistics.median(vals), 3),
                               "ci": list(bootstrap_ci(vals))}
        out[key] = {
            "n_runs": len(eligible), "n_all": len(members),
            "sufficient": len(eligible) >= MIN_SAMPLE,
            "metrics": metrics,
            "abandon_rate": (1 - len(eligible) / len(members)) if members else None,
            "run_ids": sorted(c["run_id"] for c in eligible),
        }
    return out


# ---------------------------------------------------------------- storage

def write_snapshot(out: Path, snapshot: dict) -> Path:
    d = Path(out) / "snapshots"
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{snapshot['snapshot_id']}.json"
    p.write_text(json.dumps(snapshot, indent=1, sort_keys=True), encoding="utf-8")
    return p


def load_snapshots(out: Path):
    snaps = []
    for p in sorted((Path(out) / "snapshots").glob("*.json")):
        try:
            snaps.append(json.loads(p.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return snaps


def load_baseline(out: Path):
    p = Path(out) / "baseline.json"
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _read_labels(path: str) -> dict:
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict) and "labels" in raw:
        raw = raw["labels"]
    if isinstance(raw, list):
        return {e["id"]: e for e in raw if isinstance(e, dict) and e.get("id")}
    if isinstance(raw, dict):
        return {k: (v if isinstance(v, dict) else {"label": v}) for k, v in raw.items()}
    return {}


def cmd_finalize(args) -> int:
    out = Path(args.out)
    caches = load_cache(out)
    if not caches:
        print("No collected runs. Run `collect` first.")
        return 0
    labels = _read_labels(args.labels)
    fallbacks = 0
    for cache in caches.values():
        fb = apply_labels(cache, labels)
        if fb or any(t.get("label_source") == "judge" for t in cache.get("turns") or []):
            cache["judge_model"] = args.judge_model
        cache["judge_fallbacks"] = (cache.get("judge_fallbacks") or 0) + fb
        fallbacks += fb
        compute_run_metrics(cache)
        save_cache(out, cache)
    ordered = sorted(caches.values(), key=lambda c: c.get("started_at") or "")
    snapshot = {
        "snapshot_id": dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "created_at": now_iso(), "by": args.by, "plugin_version": args.plugin_version,
        "rubric_version": RUBRIC_VERSION, "judge_model": args.judge_model,
        "judge_fallbacks": fallbacks, "malformed_lines": 0,
        "groups": aggregate(ordered, args.by),
        "run_ids": sorted(caches),
        "unlinked": [{"run_id": c["run_id"], "project": c.get("project"), "ticket_id": c.get("ticket_id"),
                      "reason": "no transcript matched"}
                     for c in ordered if c.get("eligible") and c.get("link_method") == "unlinked"],
    }
    # Guarantee unique ids when two finalize calls land in the same second.
    existing = {s["snapshot_id"] for s in load_snapshots(out)}
    while snapshot["snapshot_id"] in existing:
        snapshot["snapshot_id"] += "x"
    path = write_snapshot(out, snapshot)
    print(f"snapshot written: {path}")
    return 0


def cmd_baseline(args) -> int:
    out = Path(args.out)
    if args.action == "set":
        if not args.version:
            print("baseline set requires a version", file=sys.stderr)
            return 2
        out.mkdir(parents=True, exist_ok=True)
        (out / "baseline.json").write_text(json.dumps({"version": args.version, "set_at": now_iso()}, indent=1),
                                           encoding="utf-8")
        print(f"baseline set to {args.version}")
        return 0
    b = load_baseline(out)
    print(f"baseline: {b['version']} (set {b['set_at']})" if b else "no baseline pinned")
    return 0


COMMANDS["finalize"] = cmd_finalize
COMMANDS["baseline"] = cmd_baseline


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


if __name__ == "__main__":
    sys.exit(main())
