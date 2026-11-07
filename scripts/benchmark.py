#!/usr/bin/env python3
"""N1 orchestrator benchmark.

Measures, per N1 version, how many human interventions a pipeline run needed,
plus telemetry-derived quality metrics. Persists per-run caches, snapshots,
and reports under an output directory (default ~/.n1/benchmark/).

Usage:
  python3 scripts/benchmark.py collect  [--n1-root DIR] [--projects-dir DIR] [--out DIR] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--force] [--ambiguous-out FILE]
  python3 scripts/benchmark.py finalize --labels FILE [--out DIR] [--by version|week] [--plugin-version V] [--judge-model M]
  python3 scripts/benchmark.py report   [--out DIR] [--snapshot ID] [--by version|week]
  python3 scripts/benchmark.py baseline set <host/version|version> | show [--out DIR]

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
import re
import statistics
import sys
from pathlib import Path

RUBRIC_VERSION = 1
DEFAULT_JUDGE_MODEL = "claude-haiku-4-5-20251001"
ELIGIBLE_OUTCOMES = {"pr_created", "investigation_complete"}
MIN_SAMPLE = 5
TEXT_LIMIT = 600
LABELS = {"answer", "approval", "correction", "instruction", "noise"}
FALLBACK_LABEL = "instruction"
SUCCESS_STEP = {"success", "succeeded", "pass"}
SKIPPED_STEP = {"skip", "skipped"}
OVERVIEW_KEYS = ("final_outcome", "step", "tier", "planning_need", "pr_url")
_PR_LINE = re.compile(r"^(?:pr|pr_url):\s*(\S.*)$")


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


def count_tool_calls(path: Path):
    """Read a Claude Code transcript JSONL and count tool_use events from the orchestrator.

    Returns (bash_calls, api_calls):
      bash_calls — tool_use items whose name is "Bash"
      api_calls  — all tool_use items
    Sidechain assistant records are excluded to isolate the orchestrator.
    """
    bash_calls, api_calls = 0, 0
    for rec, _ in read_jsonl(path):
        if not rec or rec.get("type") != "assistant" or rec.get("isSidechain"):
            continue
        content = (rec.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_use":
                api_calls += 1
                if item.get("name") == "Bash":
                    bash_calls += 1
    return bash_calls, api_calls


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
    runs = list(by_id.values())
    # N1-482: infer an empty final_outcome in memory (never written back). Overview
    # signals are per ticket, so only the ticket's last run (max started_at) gets them.
    last = {}
    ov_by_dir = {}
    for rec in runs:
        d = _ticket_dir(rec)
        if d not in ov_by_dir:
            ov_by_dir[d] = _overview_signals(rec["_source_path"])
        rec["_ov"] = ov_by_dir[d]
        cur = last.get(d)
        if cur is None or (rec.get("started_at") or "") >= (cur.get("started_at") or ""):
            last[d] = rec
    for rec in runs:
        if rec.get("final_outcome"):
            continue
        inferred = infer_outcome(rec, rec["_ov"], last[_ticket_dir(rec)] is rec)
        if inferred:
            rec["final_outcome"], rec["outcome_inferred"] = inferred, True
    return runs, malformed


def is_eligible(run: dict) -> bool:
    return run.get("final_outcome") in ELIGIBLE_OUTCOMES


def _ticket_dir(rec: dict) -> str:
    """<ticket> dir of <ticket>/telemetry/runs/<run_id>.jsonl (same parent walk as raw_agents_session_path)."""
    return str(Path(rec["_source_path"]).parent.parent.parent)


def _overview_signals(src_path) -> dict:
    """Read <ticket>/overview.md beside a run file. Returns the OVERVIEW_KEYS found in the
    frontmatter; pr_url also from pr:/pr_url: lines under ## Pending or ## Finish. {} if unreadable."""
    if not src_path:
        return {}
    try:
        text = (Path(src_path).parent.parent.parent / "overview.md").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    lines = text.splitlines()
    out, body = {}, lines
    if lines and lines[0].strip() == "---":
        end = next((j for j in range(1, len(lines)) if lines[j].strip() == "---"), len(lines))
        for line in lines[1:end]:
            key, sep, val = line.partition(":")
            key, val = key.strip(), val.strip().strip("\"'")
            if sep and key in OVERVIEW_KEYS and val and val.lower() != "null":
                out[key] = val
        body = lines[end + 1:]
    section = None
    for line in body:
        if line.startswith("## "):
            section = line[3:].strip()
        elif section in ("Pending", "Finish") and "pr_url" not in out:
            m = _PR_LINE.match(line.strip())
            if m:
                out["pr_url"] = m.group(1).strip()
    return out


def _step_outcomes(rec: dict, name: str) -> set:
    return {str(s.get("outcome") or "").lower() for s in rec.get("steps") or []
            if isinstance(s, dict) and s.get("step") == name}


def infer_outcome(rec: dict, ov: dict, is_last: bool) -> str:
    """Outcome for a run whose final_outcome is empty (N1-482). Order: overview final_outcome
    (last run only); succeeded pr step or codex-review decision with pr_url/branch; overview
    pr_url (last run only); pr_skipped; investigation_complete. "" when nothing applies."""
    ov = ov if is_last else {}
    if ov.get("final_outcome"):
        return ov["final_outcome"]
    pr_steps = _step_outcomes(rec, "pr")
    if pr_steps & SUCCESS_STEP:
        return "pr_created"
    for d in rec.get("decisions") or []:
        if isinstance(d, dict) and d.get("id") == "codex-review":
            sig = d.get("signals") or {}
            if sig.get("pr_url") or sig.get("branch"):
                return "pr_created"
    if ov.get("pr_url"):
        return "pr_created"
    if pr_steps & SKIPPED_STEP and ov.get("step") == "done":
        return "pr_skipped"
    if _step_outcomes(rec, "investigation-deliverable") & SUCCESS_STEP:
        return "investigation_complete"
    return ""


def _light_fields(run: dict) -> dict:
    """Cache fields that never need a transcript: inference flag, tier, plan path."""
    ov = run.get("_ov") or {}
    return {"outcome_inferred": bool(run.get("outcome_inferred")),
            "tier": ov.get("tier") or run.get("estimated_tier") or "unknown",
            "plan_path": ov.get("planning_need") or "none"}


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
    for ev in iter_events(path):
        if ev["kind"] == "user":
            ts = parse_ts(ev["timestamp"])
            if ts is not None:
                out.append(ts)
    return out


def _transcript_mentions(path: Path, needle: str) -> bool:
    try:
        pattern = re.compile(r'(?<!\w)' + re.escape(needle) + r'(?!\w)')
        with open(path, encoding="utf-8", errors="replace") as fh:
            return any(pattern.search(line) for line in fh)
    except OSError:
        return False


def link_transcript(run: dict, projects_dir: Path):
    """Return (transcript_path, method). method: run_record | agent_event | heuristic | unlinked."""
    inline = run.get("session_transcript_path")
    if inline and Path(inline).is_file():
        return inline, "run_record"
    direct = raw_agents_session_path(run)
    if direct and Path(direct).is_file():
        return direct, "agent_event"

    start, end = parse_ts(run.get("started_at")), parse_ts(run.get("completed_at"))
    ticket = run.get("ticket_id") or ""
    if start is None or end is None or not ticket:
        return None, "unlinked"

    best, best_count = None, 0
    candidates = [p for d in candidate_project_dirs(projects_dir, run.get("project") or "", run.get("branch"))
                  for p in sorted(d.glob("*.jsonl"))]
    for path in candidates:
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


def iter_events_claude(path):
    """Normalized events from a Claude Code transcript."""
    for rec, _ in read_jsonl(Path(path)):
        if not rec:
            continue
        if rec.get("type") == "assistant" and not rec.get("isSidechain"):
            text, asked = _assistant_text_and_ask(rec)
            yield {"kind": "assistant", "timestamp": rec.get("timestamp"), "text": text, "tool": None, "asked": False}
            if asked:
                yield {"kind": "tool_call", "timestamp": rec.get("timestamp"), "text": "", "tool": "AskUserQuestion", "asked": True}
            continue
        if is_human_turn(rec):
            yield {"kind": "user", "timestamp": rec.get("timestamp"), "text": turn_text(rec) or "", "tool": None, "asked": False}


def iter_events(path):
    return iter_events_claude(path)


def extract_turns(transcript_path: str, run: dict):
    turns = []
    prev_text, prev_ask = "", False
    n = 0
    for ev in iter_events(transcript_path):
        if ev["kind"] == "assistant":
            prev_text, prev_ask = ev["text"], False
            continue
        if ev["kind"] == "tool_call":
            prev_ask = prev_ask or ev["asked"]
            continue
        ts = parse_ts(ev["timestamp"])
        turns.append({
            "id": f"{run['run_id']}#{n}",
            "timestamp": ev["timestamp"],
            "step": step_at(run, ts) if ts is not None else "outside",
            "text": ev["text"][:TEXT_LIMIT],
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
        "host": run.get("host") or "unknown",
        "project": run.get("project"), "ticket_id": run.get("ticket_id"),
        "started_at": run.get("started_at"), "completed_at": run.get("completed_at"),
        "final_outcome": run.get("final_outcome"), "eligible": eligible,
        "link_method": "skipped", "transcript_path": None, "turns": [],
        "metrics": {}, "per_step": {}, "judge_model": None,
        "rubric_version": RUBRIC_VERSION, "judge_fallbacks": 0, "collected_at": now_iso(),
        "_run": run,
    }
    cache["questions"] = _extract_questions(run)
    cache.update(_light_fields(run))
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


def _extract_questions(run: dict) -> list:
    """Extract question events from raw step JSONL if not already in the merged record."""
    if run.get("questions"):
        return run["questions"]
    src = run.get("_source_path")
    if not src:
        return []
    raw = Path(src).parent.parent / "raw" / "steps" / f"{run['run_id']}.jsonl"
    if not raw.is_file():
        return []
    questions = []
    for rec, _ in read_jsonl(raw):
        if rec and rec.get("event") == "question":
            questions.append({
                "step": rec.get("step", ""),
                "question_category": rec.get("question_category", ""),
                "resolution": rec.get("resolution", ""),
                "rungs_tried": rec.get("rungs_tried", ""),
            })
    return questions


def _strip_private(cache: dict) -> dict:
    return {k: v for k, v in cache.items() if not k.startswith("_")}


def cmd_collect(args) -> int:
    out = Path(args.out)
    runs, malformed = load_runs(Path(args.n1_root))
    since = parse_ts(f"{args.since}T00:00:00Z") if args.since else None
    until = parse_ts(f"{args.until}T00:00:00Z") if args.until else None
    if until is not None:
        until += 86400  # inclusive end-of-day
    if since is not None or until is not None:
        # Undated runs are excluded when any bound is set (matches telemetry_analyzer).
        def in_window(r):
            ts = parse_ts(r.get("started_at"))
            return ts is not None and (since is None or ts >= since) and (until is None or ts < until)
        runs = [r for r in runs if in_window(r)]
    # Transcript parsing only understands Claude Code records; drop historical
    # Codex runs instead of collecting them with garbage (zero turns/calls) metrics.
    skipped_host = sum(1 for r in runs if r.get("host") == "codex")
    runs = [r for r in runs if r.get("host") != "codex"]
    if skipped_host:
        print(f"skipped {skipped_host} run(s) with unsupported host (codex)", file=sys.stderr)
    existing = {} if args.force else load_cache(out)
    new, cached, ambiguous = 0, 0, []
    for run in runs:
        cache = existing.get(run["run_id"])
        if cache is not None and not cache.get("eligible") and is_eligible(run):
            # N1-482: outcome newly inferred. Ineligible caches hold no turns or labels,
            # so rebuilding loses nothing and needs no --force.
            cache = None
        if cache is None:
            cache = build_run_cache(run, Path(args.projects_dir))
            cache["run_record"] = {k: v for k, v in run.items() if not k.startswith("_")}
            save_cache(out, _strip_private(cache))
            new += 1
        else:
            if "tier" not in cache:
                cache.update(_light_fields(run))
                save_cache(out, _strip_private(cache))
            cached += 1
        for t in cache["turns"]:
            if t.get("label") == "ambiguous":
                ambiguous.append({"id": t["id"], "text": t["text"], "prev_assistant": t["prev_assistant"]})
    result = {"ambiguous": ambiguous, "runs_new": new, "runs_cached": cached,
              "runs_total": len(runs), "malformed_lines": malformed, "runs_skipped_host": skipped_host}
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

    def __init__(self, name, labels, *, exclude_steps=None, only_steps=None):
        self.name, self.labels = name, set(labels)
        self.exclude_steps = frozenset(exclude_steps) if exclude_steps else frozenset()
        self.only_steps = frozenset(only_steps) if only_steps else None

    def _filter(self, turns):
        for t in turns:
            step = t.get("step") or "outside"
            if step in self.exclude_steps:
                continue
            if self.only_steps is not None and step not in self.only_steps:
                continue
            yield t

    def compute(self, run_record, turns):
        if turns is None:
            return None
        return float(sum(1 for t in self._filter(turns) if t.get("label") in self.labels))


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
        if (run_record.get("parser_schema_version") or 0) < 6:
            return None
        val = (run_record.get("summary") or {}).get("compaction_count")
        return float(val) if isinstance(val, (int, float)) else None


class CacheCreationTokensMetric(Metric):
    name, unit, direction = "cache_creation_tokens", "tokens", "lower"

    def compute(self, run_record, turns):
        val = (run_record.get("summary") or {}).get("total_cache_creation_tokens")
        return float(val) if isinstance(val, (int, float)) else None


class QuestionMetric(Metric):
    """Questions asked per run, optionally filtered by step or resolution."""
    unit = "count"
    direction = "lower"

    def __init__(self, name, *, only_steps=None, only_resolutions=None):
        self.name = name
        self.only_steps = frozenset(only_steps) if only_steps else None
        self.only_resolutions = frozenset(only_resolutions) if only_resolutions else None

    def compute(self, run_record, turns):
        questions = [e for e in (run_record.get("questions") or [])
                     if isinstance(e, dict)]
        if self.only_steps:
            questions = [q for q in questions if q.get("step") in self.only_steps]
        if self.only_resolutions:
            questions = [q for q in questions if q.get("resolution") in self.only_resolutions]
        return float(len(questions))


class QuestionShareMetric(Metric):
    """Share of questions with a specific resolution, as a ratio 0-1."""
    unit = "ratio"

    def __init__(self, name, resolution, *, direction="higher"):
        self.name = name
        self.resolution = resolution
        self.direction = direction

    def compute(self, run_record, turns):
        questions = [e for e in (run_record.get("questions") or [])
                     if isinstance(e, dict)]
        if not questions:
            return None
        matched = sum(1 for q in questions if q.get("resolution") == self.resolution)
        return round(matched / len(questions), 3)


class BashCallsMetric(Metric):
    """Bash tool invocations per run (pre-computed in compute_run_metrics)."""
    name, unit, direction = "bash_calls_per_run", "count", "lower"

    def compute(self, run_record, turns):
        v = run_record.get("_bash_calls")
        return float(v) if isinstance(v, (int, float)) else None


class ApiCallsMetric(Metric):
    """Total tool_use items from the orchestrator per run (pre-computed in compute_run_metrics)."""
    name, unit, direction = "api_calls_per_run", "count", "lower"

    def compute(self, run_record, turns):
        v = run_record.get("_api_calls")
        return float(v) if isinstance(v, (int, float)) else None


class OrchestratorApiCallsMetric(Metric):
    """Orchestrator API calls per run (from merged run record orchestrator.totals)."""
    name, unit, direction = "orchestrator_api_calls_per_run", "count", "lower"

    def compute(self, run_record, turns):
        v = run_record.get("_orch_api_calls")
        return float(v) if isinstance(v, (int, float)) else None


class OrchestratorBashCallsMetric(Metric):
    """Orchestrator Bash calls per run (from merged run record orchestrator.totals)."""
    name, unit, direction = "orchestrator_bash_calls_per_run", "count", "lower"

    def compute(self, run_record, turns):
        v = run_record.get("_orch_bash_calls")
        return float(v) if isinstance(v, (int, float)) else None


class OrchestratorInputTokensMetric(Metric):
    """Orchestrator input tokens per run (from merged run record orchestrator.totals)."""
    name, unit, direction = "orchestrator_input_tokens_per_run", "count", "lower"

    def compute(self, run_record, turns):
        v = run_record.get("_orch_input_tokens")
        return float(v) if isinstance(v, (int, float)) else None


class OrchestratorCostRatioMetric(Metric):
    """Fraction of input tokens consumed by the orchestrator vs all agents (0-1)."""
    name, unit, direction = "orchestrator_cost_ratio", "ratio", "lower"

    def compute(self, run_record, turns):
        orch = run_record.get("_orch_input_tokens")
        total = run_record.get("_total_input_tokens")
        if not isinstance(orch, (int, float)) or not isinstance(total, (int, float)):
            return None
        return round(orch / total, 4) if total > 0 else None


INTERACTIVE_STEPS = frozenset({"brainstorm"})

METRICS = [
    TurnCountMetric("interventions", {"answer", "correction"}, exclude_steps={"outside"}),
    TurnCountMetric("answers", {"answer"}, exclude_steps={"outside"}),
    TurnCountMetric("corrections", {"correction"}, exclude_steps={"outside"}),
    TurnCountMetric("brainstorm_interactions", {"answer", "correction", "approval", "instruction"},
                    only_steps=INTERACTIVE_STEPS),
    TurnCountMetric("autonomous_interventions", {"answer", "correction"},
                    exclude_steps={"outside"} | INTERACTIVE_STEPS),
    OutcomeMetric("fix_cycles", "fix_cycles_count", "count", "lower"),
    OutcomeMetric("review_pass_first_try", "review_pass_first_try", "ratio", "higher", boolean=True),
    DurationMetric(),
    OrchestratorTokensMetric(),
    CompactionsMetric(),
    CacheCreationTokensMetric(),
    QuestionMetric("questions_per_run"),
    QuestionMetric("brainstorm_questions", only_steps={"brainstorm"}),
    QuestionShareMetric("recommended_followed_share", "auto-decided"),
    QuestionShareMetric("decide_for_me_share", "decide-for-me"),
    QuestionShareMetric("inherited_share", "inherited"),
    # Tool efficiency
    BashCallsMetric(),
    ApiCallsMetric(),
    OrchestratorApiCallsMetric(),
    OrchestratorBashCallsMetric(),
    OrchestratorInputTokensMetric(),
    OrchestratorCostRatioMetric(),
]
TURN_METRICS = [m for m in METRICS if isinstance(m, TurnCountMetric)]


def compute_run_metrics(cache: dict) -> None:
    run_record = cache.get("run_record") or {}
    run_record["questions"] = cache.get("questions", [])
    # Pre-compute tool call counts so BashCallsMetric / ApiCallsMetric can read them.
    transcript_path = cache.get("transcript_path")
    if transcript_path and Path(transcript_path).is_file():
        bash_c, api_c = count_tool_calls(Path(transcript_path))
        run_record["_bash_calls"] = bash_c
        run_record["_api_calls"] = api_c
    # Orchestrator metrics from merged run record
    orch = run_record.get("orchestrator") or {}
    totals = orch.get("totals") or {}
    run_record["_orch_api_calls"] = totals.get("api_calls")
    run_record["_orch_bash_calls"] = (totals.get("tools_used") or {}).get("Bash")
    run_record["_orch_input_tokens"] = totals.get("input_tokens")
    run_record["_orch_output_tokens"] = totals.get("output_tokens")
    # v4 combined incomparable host scopes and could label a final request as
    # complete session usage. Keep those records, but do not benchmark totals.
    comparable = (run_record.get("parser_schema_version") or 0) >= 5 and run_record.get("usage_status") == "complete"
    run_record["_total_input_tokens"] = (run_record.get("summary") or {}).get("total_input_tokens") if comparable else None
    if comparable and run_record.get('host') == 'claude-code' and totals:
        values = [totals.get(k) for k in ('input_tokens', 'cache_read_tokens', 'cache_creation_tokens')]
        run_record['_orch_input_tokens'] = sum(values) if all(v is not None for v in values) else None
    turns = cache.get("turns") or []
    linked = cache.get("link_method", "heuristic") in ("run_record", "agent_event", "heuristic")
    turn_arg = turns if linked else None
    cache["metrics"] = {m.name: m.compute(run_record, turn_arg) for m in METRICS}
    per_step = {}
    if linked:
        for step in sorted({t.get("step") or "outside" for t in turns}):
            subset = [t for t in turns if (t.get("step") or "outside") == step]
            per_step[step] = {m.name: m.compute(run_record, subset) for m in TURN_METRICS}
    cache["per_step"] = per_step
    # Per-step question counts
    questions = cache.get("questions", [])
    question_by_step = {}
    for q in questions:
        step = q.get("step") or "outside"
        if step not in question_by_step:
            question_by_step[step] = {"total": 0, "asked": 0, "auto": 0, "decide_for_me": 0, "inherited": 0}
        question_by_step[step]["total"] += 1
        res = q.get("resolution", "")
        if res in question_by_step[step]:
            question_by_step[step][res] += 1
    cache["question_by_step"] = question_by_step


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


LEGACY = "legacy"


def group_key(cache: dict, by: str) -> str:
    """host/version or host/ISO-week; LEGACY when host, version (version mode) or start time (week mode) is unknown."""
    host = cache.get("host") or "unknown"
    if host == "unknown":
        return LEGACY
    if by == "week":
        ts = parse_ts(cache.get("started_at"))
        if ts is None:
            return LEGACY
        iso = dt.datetime.fromtimestamp(ts, dt.timezone.utc).isocalendar()
        return f"{host}/{iso[0]}-W{iso[1]:02d}"
    version = cache.get("n1_version") or "unknown"
    if version == "unknown":
        return LEGACY
    return f"{host}/{version}"


def is_legacy_key(key: str) -> bool:
    """LEGACY, or a pre-N1-482 key with an unknown part (unknown/unknown, unknown/3.28.4, claude-code/unknown)."""
    return key == LEGACY or "unknown" in key.split("/")


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


CODEX_REVIEW_OUTCOMES = ("ran", "skipped", "failed", "timeout")


def codex_review_prs(cache: dict):
    """Latest Codex-review outcome per PR reviewed in a run (N1-482).

    Decisions are keyed by pr_url, else signals.branch, within the run; the last
    decision per key wins. No final_outcome gate. A run with no decision whose
    (possibly inferred) cache final_outcome is pr_created counts one PR as missing.
    """
    run = cache.get("run_record") or {}
    by_key = {}
    for decision in run.get("decisions") or []:
        if not isinstance(decision, dict) or decision.get("id") != "codex-review":
            continue
        signals = decision.get("signals") or {}
        pr_url = signals.get("pr_url") or decision.get("pr_url")
        outcome = signals.get("outcome") or decision.get("outcome")
        by_key[pr_url or signals.get("branch")] = {
            "pr_url": pr_url, "outcome": outcome if outcome in CODEX_REVIEW_OUTCOMES else "missing"}
    if by_key:
        return list(by_key.values())
    if cache.get("final_outcome") == "pr_created":
        return [{"pr_url": None, "outcome": "missing"}]
    return []


UNLINKABLE_CAUSES = ("no project", "no timestamps")


def unlink_cause(c: dict) -> str:
    """Why an eligible run has no transcript. The first two cannot link by construction
    (link_transcript needs a project dir and both timestamps)."""
    if not c.get("project"):
        return "no project"
    if not c.get("started_at") or not c.get("completed_at"):
        return "no timestamps"
    return "no transcript matched"


def _stat(vals):
    vals = [v for v in vals if isinstance(v, (int, float))]
    if not vals:
        return None
    return {"n": len(vals), "mean": round(statistics.fmean(vals), 3),
            "median": round(statistics.median(vals), 3), "ci": list(bootstrap_ci(vals))}


def aggregate(caches, by: str, keyfn=None) -> dict:
    keyfn = keyfn or (lambda c: group_key(c, by))
    groups = {}
    for c in caches:
        groups.setdefault(keyfn(c), []).append(c)
    out = {}
    for key, members in groups.items():
        eligible = [c for c in members if c.get("eligible")]
        metrics = {m.name: _stat([c["metrics"].get(m.name) for c in eligible]) for m in METRICS}
        cell_vals = {}
        for c in eligible:
            cell_vals.setdefault(f"{c.get('tier') or 'unknown'}/{c.get('plan_path') or 'none'}", []).append(
                c["metrics"].get("interventions"))
        # Gate activation rates for this group's eligible runs
        gate_stats: dict = {}
        for c in eligible:
            rr = c.get("run_record") or {}
            for dec in (rr.get("decisions") or []):
                did = dec.get("id", "")
                if not did:
                    continue
                res = dec.get("result", False)
                if did not in gate_stats:
                    gate_stats[did] = {"true": 0, "total": 0}
                gate_stats[did]["total"] += 1
                if res:
                    gate_stats[did]["true"] += 1
        gate_activation_rates = {
            did: round(100 * v["true"] / v["total"], 1) if v["total"] else None
            for did, v in gate_stats.items()
        }
        unlinked = [c for c in eligible if c.get("link_method") == "unlinked"]
        n_unlinked = len(unlinked)
        denom = len(eligible) - sum(1 for c in unlinked if unlink_cause(c) in UNLINKABLE_CAUSES)
        quality_coverage = round((len(eligible) - n_unlinked) / denom, 3) if denom > 0 else None
        review_prs = [(c, pr) for c in members for pr in codex_review_prs(c)]
        outcomes = {outcome: sum(1 for _, pr in review_prs if pr["outcome"] == outcome)
                    for outcome in (*CODEX_REVIEW_OUTCOMES, "missing")}
        reviewed_runs = {c.get("run_id") for c, pr in review_prs if pr["outcome"] == "ran"}
        pr_runs = {c.get("run_id") for c, _ in review_prs}
        reviewed_prs = outcomes["ran"]
        pr_count = len(review_prs)
        out[key] = {
            "n_runs": len(eligible), "n_all": len(members),
            "n_incomplete": len(members) - len(eligible),
            "n_unlinked": n_unlinked,
            "n_inferred": sum(1 for c in eligible if c.get("outcome_inferred")),
            "cells": {k: _stat(v) for k, v in cell_vals.items()},
            "quality_coverage": quality_coverage,
            "sufficient": len(eligible) >= MIN_SAMPLE,
            "metrics": metrics,
            "abandon_rate": (1 - len(eligible) / len(members)) if members else None,
            "run_ids": sorted(c["run_id"] for c in eligible),
            "gate_activation_rates": gate_activation_rates,
            "codex_review": {
                "pr_runs": len(pr_runs), "prs": pr_count,
                "reviewed_runs": len(reviewed_runs), "reviewed_prs": reviewed_prs,
                "coverage_rate": round(reviewed_prs / pr_count, 3) if pr_count else None,
                "outcomes": outcomes,
            },
        }
    return out


def merge_versions(caches) -> dict:
    """Map 'host/version' to a headline bucket: adjacent versions of one host are joined
    (ascending) until the bucket has MIN_SAMPLE eligible runs; an undersized tail joins the
    previous bucket. A host with one undersized bucket keeps it (insufficient). Legacy excluded."""
    counts = {}
    for c in caches:
        k = group_key(c, "version")
        if not is_legacy_key(k):
            counts[k] = counts.get(k, 0) + (1 if c.get("eligible") else 0)
    by_host = {}
    for k in counts:
        host, _, v = k.partition("/")
        by_host.setdefault(host, []).append(v)
    mapping = {}
    for host, versions in by_host.items():
        buckets, cur, n = [], [], 0
        for v in sorted(versions, key=version_key):
            cur.append(v)
            n += counts[f"{host}/{v}"]
            if n >= MIN_SAMPLE:
                buckets.append(cur)
                cur, n = [], 0
        if cur:
            if buckets:
                buckets[-1] += cur
            else:
                buckets.append(cur)
        for b in buckets:
            label = f"{host}/{b[0]}" if len(b) == 1 else f"{host}/{b[0]}-{b[-1]}"
            for v in b:
                mapping[f"{host}/{v}"] = label
    return mapping


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
    # Drop stale Codex caches collected before host filtering was added — their
    # transcripts were never parsed, so metrics are zeroed and would skew aggregates.
    skipped_host = [rid for rid, c in caches.items() if c.get("host") == "codex"]
    for rid in skipped_host:
        del caches[rid]
    if skipped_host:
        print(f"skipped {len(skipped_host)} cached run(s) with unsupported host (codex)", file=sys.stderr)
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
    unlinked = [c for c in ordered if c.get("eligible") and c.get("link_method") == "unlinked"]
    causes = {}
    for c in unlinked:
        causes[unlink_cause(c)] = causes.get(unlink_cause(c), 0) + 1
    snapshot = {
        "snapshot_id": dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "created_at": now_iso(), "by": args.by, "plugin_version": args.plugin_version,
        "rubric_version": RUBRIC_VERSION, "judge_model": args.judge_model,
        "judge_fallbacks": fallbacks, "malformed_lines": 0,
        "groups": aggregate(ordered, args.by),
        "run_ids": sorted(caches),
        "unlinked": [{"run_id": c["run_id"], "project": c.get("project"), "ticket_id": c.get("ticket_id"),
                      "reason": unlink_cause(c)} for c in unlinked],
        "unlinked_causes": causes,
    }
    if args.by == "version":
        bucket = merge_versions(ordered)
        members = [c for c in ordered if group_key(c, "version") in bucket]
        merged = aggregate(members, "version", keyfn=lambda c: bucket[group_key(c, "version")])
        for label, grp in merged.items():
            grp["versions"] = sorted((k for k, b in bucket.items() if b == label),
                                     key=lambda k: version_key(k.partition("/")[2]))
        snapshot["merged"] = merged
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
        snaps = load_snapshots(out)
        if not snaps:
            print("baseline set: no snapshot found; run finalize first", file=sys.stderr)
            return 2
        snap = snaps[-1]
        valid = [k for k in _sorted_groups(snap) if not is_legacy_key(k)]
        value = args.version
        if value not in valid:
            matches = [k for k in valid if k.partition("/")[2] == value]
            if len(matches) != 1:
                print(f"baseline set: {value!r} is not a partition of snapshot {snap['snapshot_id']} "
                      f"(by {snap.get('by', 'version')}). Valid: {', '.join(valid[:10]) or 'none'}", file=sys.stderr)
                return 2
            value = matches[0]
        out.mkdir(parents=True, exist_ok=True)
        (out / "baseline.json").write_text(json.dumps({"version": value, "set_at": now_iso()}, indent=1),
                                           encoding="utf-8")
        print(f"baseline set to {value}")
        return 0
    b = load_baseline(out)
    print(f"baseline: {b['version']} (set {b['set_at']})" if b else "no baseline pinned")
    return 0


COMMANDS["finalize"] = cmd_finalize
COMMANDS["baseline"] = cmd_baseline


# ------------------------------------------------------------------ report

def delta(cur: dict, ref: dict) -> dict:
    a = round(cur["mean"] - ref["mean"], 3)
    pct = round(a / ref["mean"] * 100, 1) if ref["mean"] else None
    significant = cur["ci"][0] > ref["ci"][1] or cur["ci"][1] < ref["ci"][0]
    return {"abs": a, "pct": pct, "significant": bool(significant)}


def _group_sort_key(key: str, by: str):
    """Sort key for 'host/version', 'host/first-last' (merged) or 'host/week'."""
    host, _, rest = key.partition("/")
    if by == "week":
        return (host, rest)
    return (host, version_key(rest.split("-", 1)[0]))


def _sorted_groups(snapshot: dict, groups=None):
    groups = snapshot["groups"] if groups is None else groups
    by = snapshot.get("by", "version")
    legacy = sorted(k for k in groups if is_legacy_key(k))
    known = [k for k in groups if not is_legacy_key(k)]
    return sorted(known, key=lambda k: _group_sort_key(k, by)) + legacy


def _sufficient_groups(snapshot: dict, groups=None):
    groups = snapshot["groups"] if groups is None else groups
    return [k for k in _sorted_groups(snapshot, groups) if groups[k]["sufficient"] and not is_legacy_key(k)]


def latest_sufficient(snapshot: dict, groups=None):
    keys = _sufficient_groups(snapshot, groups)
    return keys[-1] if keys else None


def headline_groups(snapshot: dict) -> dict:
    """Partitions the headline compares: merged buckets (version mode), non-legacy weeks
    (week mode), {} for a pre-N1-482 version snapshot."""
    if "merged" in snapshot:
        return snapshot["merged"]
    if snapshot.get("by") == "week":
        return {k: v for k, v in snapshot["groups"].items() if not is_legacy_key(k)}
    return {}


def pick_baseline_group(snapshot: dict, baseline):
    hg = headline_groups(snapshot) or snapshot["groups"]
    sufficient = _sufficient_groups(snapshot, hg)
    host = sufficient[-1].partition("/")[0] if sufficient else None
    fallback = next((k for k in sufficient if k.partition("/")[0] == host), None)
    pinned = (baseline or {}).get("version")
    if pinned:
        if pinned in hg and not is_legacy_key(pinned):
            return pinned, "pinned"
        bucket = next((k for k, v in hg.items() if pinned in (v.get("versions") or [])), None)
        if bucket:
            return bucket, f"pinned {pinned}"
        return fallback, f"pinned baseline {pinned} not in this snapshot; using oldest sufficient {host} partition"
    return fallback, "no baseline pinned; using oldest sufficient partition"


def _fmt_stat(s):
    if not s:
        return "n/a"
    return f"{s['mean']:g} [{s['ci'][0]:g}, {s['ci'][1]:g}] (n={s['n']})"


def _fmt_delta(d, direction):
    if d is None:
        return "n/a"
    better = (d["abs"] < 0) if direction == "lower" else (d["abs"] > 0)
    arrow = "better" if better else ("worse" if d["abs"] != 0 else "same")
    pct = f", {d['pct']:+g}%" if d["pct"] is not None else ""
    sig = " significant" if d["significant"] else ""
    return f"{d['abs']:+g}{pct} ({arrow}{sig})"


def _judge_reasons(turns):
    counts = {}
    for t in turns:
        if t.get("label") == "correction" and t.get("reason"):
            counts[t["reason"]] = counts.get(t["reason"], 0) + 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:3]


def render_report(snapshot, previous, baseline_group, baseline_note, caches) -> str:
    g = snapshot["groups"]
    hg = headline_groups(snapshot) or g
    lines = [f"# N1 Orchestrator Benchmark — snapshot {snapshot['snapshot_id']}", ""]

    latest = latest_sufficient(snapshot, hg)
    if latest and baseline_group and baseline_group in hg:
        cur, ref = hg[latest]["metrics"].get("interventions"), hg[baseline_group]["metrics"].get("interventions")
        if cur and ref:
            d = delta(cur, ref)
            lines.append(f"**{latest} vs baseline {baseline_group}** ({baseline_note}): interventions "
                         f"{cur['mean']:g} vs {ref['mean']:g}, {_fmt_delta(d, 'lower')}.")
        else:
            lines.append(f"**{latest} vs baseline {baseline_group}** ({baseline_note}): no interventions data.")
    else:
        lines.append("No version has a sufficient sample yet; trends are not computed.")
    lines.append("")

    # Per-group table
    header = ["partition (host/version)", "runs", "incomplete", "unlinked", "quality_cov"] + [m.name for m in METRICS] + ["abandon_rate"]
    lines.append("## Per-partition metrics (host/version)" if snapshot.get("by") == "version" else "## Per-partition metrics (host/week)")
    lines.append("")
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "---|" * len(header))
    prev_key_by_host: dict = {}  # host -> last sufficient key, to avoid cross-host deltas
    for key in _sorted_groups(snapshot):
        grp = g[key]
        host_part = key.partition("/")[0]
        prev_key = prev_key_by_host.get(host_part)
        suffix = "" if grp["sufficient"] else " (insufficient, n<5)"
        qcov = grp.get("quality_coverage")
        row = [
            key,
            f"{grp['n_runs']}/{grp['n_all']}{suffix}",
            str(grp.get("n_incomplete", 0)),
            str(grp.get("n_unlinked", 0)),
            f"{qcov:.0%}" if qcov is not None else "n/a",
        ]
        for m in METRICS:
            cell = _fmt_stat(grp["metrics"].get(m.name))
            if grp["sufficient"] and prev_key and grp["metrics"].get(m.name) and g[prev_key]["metrics"].get(m.name):
                d = delta(grp["metrics"][m.name], g[prev_key]["metrics"][m.name])
                cell += f" {_fmt_delta(d, m.direction)}"
            row.append(cell)
        ar = grp.get("abandon_rate")
        row.append(f"{ar:.0%}" if ar is not None else "n/a")
        lines.append("| " + " | ".join(row) + " |")
        if grp["sufficient"]:
            prev_key_by_host[host_part] = key
    lines.append("")
    lines.append("Cells: mean [95% bootstrap CI] (n). Deltas compare against the previous sufficient partition of the same host.")
    legacy_keys = [k for k in _sorted_groups(snapshot) if is_legacy_key(k)]
    if legacy_keys:
        total_legacy = sum(g[k]["n_all"] for k in legacy_keys)
        lines.append(f"Note: {total_legacy} run(s) in the legacy partition (unknown host or version): "
                     f"{', '.join(legacy_keys)}; excluded from headline and baseline.")
    lines.append("")

    lines += ["## Codex review coverage", "",
              "| group | PR runs | runs reviewed | PRs reviewed | coverage | outcomes |",
              "|---|---|---|---|---|---|"]
    for key in _sorted_groups(snapshot):
        review = g[key].get("codex_review") or {}
        pr_runs = review.get("pr_runs", 0)
        prs = review.get("prs", 0)
        reviewed_runs = review.get("reviewed_runs", 0)
        reviewed_prs = review.get("reviewed_prs", 0)
        rate = review.get("coverage_rate")
        outcomes = review.get("outcomes") or {}
        outcome_text = ", ".join(f"{name} {outcomes.get(name, 0)}"
                                  for name in (*CODEX_REVIEW_OUTCOMES, "missing"))
        lines.append(f"| {key} | {pr_runs} | {reviewed_runs}/{pr_runs} | {reviewed_prs}/{prs} | "
                     f"{rate:.0%} | {outcome_text} |" if rate is not None else
                     f"| {key} | {pr_runs} | {reviewed_runs}/{pr_runs} | {reviewed_prs}/{prs} | n/a | {outcome_text} |")
    lines.append("")

    # Baseline comparison table
    if latest and baseline_group and baseline_group in hg and latest != baseline_group:
        lines += [f"## {latest} vs baseline {baseline_group}", "", "| metric | baseline | latest | delta |", "|---|---|---|---|"]
        for m in METRICS:
            cur, ref = hg[latest]["metrics"].get(m.name), hg[baseline_group]["metrics"].get(m.name)
            d = delta(cur, ref) if cur and ref else None
            lines.append(f"| {m.name} | {_fmt_stat(ref)} | {_fmt_stat(cur)} | {_fmt_delta(d, m.direction)} |")
        lines.append("")

    # Drift vs previous snapshot
    if previous:
        lines += [f"## Drift vs previous snapshot ({previous['snapshot_id']})", ""]
        drift = []
        for key in _sorted_groups(snapshot):
            pg = previous["groups"].get(key)
            if not pg:
                continue
            cur, ref = g[key]["metrics"].get("interventions"), pg["metrics"].get("interventions")
            if cur and ref and (cur["mean"] != ref["mean"] or cur["n"] != ref["n"]):
                drift.append(f"- {key}: interventions {ref['mean']:g} (n={ref['n']}) -> {cur['mean']:g} (n={cur['n']})")
        lines += drift or ["- no changes in interventions for shared versions"]
        lines.append("")

    insufficient = [k for k in _sorted_groups(snapshot) if not g[k]["sufficient"]]
    lines += ["## Insufficient sample", ""]
    lines += [f"- {k} ({g[k]['n_runs']} runs)" for k in insufficient] or ["- none"]
    lines.append("")

    causes = snapshot.get("unlinked_causes") or {}
    lines += ["## Unlinked runs", "",
              "By cause: " + (", ".join(f"{k} {n}" for k, n in sorted(causes.items())) or "n/a"), ""]
    lines += [f"- {u['run_id']} ({u.get('project')}, {u.get('ticket_id')}): {u.get('reason')}"
              for u in snapshot.get("unlinked") or []] or ["- none"]
    lines.append("")

    worst = sorted((c for c in caches.values() if c.get("eligible") and isinstance(c.get("metrics", {}).get("corrections"), (int, float))),
                   key=lambda c: -c["metrics"]["corrections"])[:5]
    lines += ["## Worst runs (most corrections)", ""]
    for c in worst:
        reasons = ", ".join(f"{r} ({n})" for r, n in _judge_reasons(c.get("turns") or []))
        lines.append(f"- {c['run_id']} [{c.get('n1_version')}] {c.get('project')}/{c.get('ticket_id')}: "
                     f"{c['metrics']['corrections']:g} corrections. {reasons or 'no judge reasons'}. {c.get('transcript_path') or ''}")
    if not worst:
        lines.append("- none")
    lines.append("")

    # Tool efficiency
    lines += ["## Tool efficiency", ""]
    lines += ["| group | bash_calls_per_run | api_calls_per_run |", "|---|---|---|"]
    for key in _sorted_groups(snapshot):
        bc = _fmt_stat(g[key]["metrics"].get("bash_calls_per_run"))
        ac = _fmt_stat(g[key]["metrics"].get("api_calls_per_run"))
        lines.append(f"| {key} | {bc} | {ac} |")
    lines.append("")
    lines.append("Cells: mean [95% bootstrap CI] (n). Lower is better.")
    lines.append("")

    # Gate activation rates
    # Collect from snapshot groups
    gate_rates = {}
    for key in snapshot.get("groups", {}):
        gr = (snapshot["groups"][key] or {}).get("gate_activation_rates") or {}
        for did, rate in gr.items():
            if did not in gate_rates:
                gate_rates[did] = rate
    if gate_rates:
        lines += ["## Gate Activation Rates", ""]
        lines += ["| gate | activation_rate |", "|---|---|"]
        for did, rate in sorted(gate_rates.items()):
            rate_str = f"{rate}%" if rate is not None else "n/a"
            lines.append(f"| {did} | {rate_str} |")
        lines.append("")

    lines.append(f"Snapshot {snapshot['snapshot_id']}, plugin {snapshot.get('plugin_version') or 'unknown'}, "
                 f"rubric v{snapshot['rubric_version']}, judge {snapshot['judge_model']}, "
                 f"judge fallbacks {snapshot['judge_fallbacks']}, malformed lines {snapshot.get('malformed_lines', 0)}. "
                 f"Previous snapshot: {previous['snapshot_id'] if previous else 'none'}.")
    return "\n".join(lines) + "\n"


def cmd_report(args) -> int:
    out = Path(args.out)
    snaps = [s for s in load_snapshots(out) if s.get("by", "version") == args.by]
    if not snaps:
        print("No snapshots found. Run `finalize` first.")
        return 0
    if args.snapshot:
        idx = next((i for i, s in enumerate(snaps) if s["snapshot_id"] == args.snapshot), None)
        if idx is None:
            print(f"snapshot not found: {args.snapshot}", file=sys.stderr)
            return 1
    else:
        idx = len(snaps) - 1
    snapshot = snaps[idx]
    previous = snaps[idx - 1] if idx > 0 else None
    baseline_group, note = pick_baseline_group(snapshot, load_baseline(out))
    text = render_report(snapshot, previous, baseline_group, note, load_cache(out))
    rp = out / "reports" / f"{snapshot['snapshot_id']}.md"
    rp.parent.mkdir(parents=True, exist_ok=True)
    rp.write_text(text, encoding="utf-8")
    print(text)
    print(f"report saved: {rp}")
    return 0


COMMANDS["report"] = cmd_report


# ------------------------------------------------------------------------ CLI

def date_arg(v):
    try:
        dt.datetime.strptime(v, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid date {v!r}, expected YYYY-MM-DD")
    return v


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
    c.add_argument("--since", type=date_arg, default=None, help="YYYY-MM-DD; ignore runs started earlier")
    c.add_argument("--until", type=date_arg, default=None, help="YYYY-MM-DD (inclusive); ignore runs started later")
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
