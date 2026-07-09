#!/usr/bin/env python3
"""Python fallback for telemetry-merge.sh — used when jq is unavailable.

Replicates the jq pipeline: pair step events, pair agent events, correlate
agents to steps (static map + temporal), parse agent transcripts for token
usage, and write the unified run record to <telemetry_dir>/runs/<run_id>.jsonl.

Stdlib only. Invoked as:
    python telemetry-merge.py <run_id> <telemetry_dir> [--n1-version V] [--project P]
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

STATIC_MAP = {
    "n1:product-analyst": ["ticket"],
    "n1:planner": ["plan"],
    "n1:code-reviewer": ["review"],
    "n1:security-reviewer": ["review"],
    "n1:codex-adapter": ["review"],
    "n1:tech-writer": ["pr"],
}


def _read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    records = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def _epoch(ts: str | None) -> float | None:
    if not ts:
        return None
    try:
        base = ts.split(".")[0].rstrip("Z")
        return datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def _duration(start: str | None, end: str | None) -> float | None:
    s, e = _epoch(start), _epoch(end)
    if s is None or e is None:
        return None
    return e - s


def pair_steps(events: list[dict]) -> list[dict]:
    groups: dict = {}
    for ev in events:
        if ev.get("layer") != "step":
            continue
        groups.setdefault(ev.get("step_number"), []).append(ev)
    steps = []
    for num, evs in groups.items():
        start = next((e for e in evs if e.get("started_at")), None)
        end = next((e for e in evs if e.get("completed_at")), None)
        ref = start or end or {}
        steps.append({
            "step": ref.get("step"),
            "step_number": num,
            "started_at": (start or {}).get("started_at"),
            "completed_at": (end or {}).get("completed_at"),
            "duration_s": _duration((start or {}).get("started_at"), (end or {}).get("completed_at")),
            "outcome": (end or {}).get("outcome", "interrupted"),
            "loop_iteration": (end or {}).get("loop_iteration"),
            "metadata": (end or {}).get("metadata", {}),
        })
    steps.sort(key=lambda s: (s["step_number"] is None, s["step_number"]))
    return steps


def pair_agents(events: list[dict]) -> list[dict]:
    groups: dict = {}
    for ev in events:
        groups.setdefault(ev.get("agent_id"), []).append(ev)
    agents = []
    for _aid, evs in groups.items():
        start = next((e for e in evs if e.get("event") == "start"), None)
        stop = next((e for e in evs if e.get("event") == "stop"), None)
        ref = start or stop or {}
        agents.append({
            "agent_id": ref.get("agent_id"),
            "agent_type": ref.get("agent_type"),
            "started_at": (start or {}).get("started_at"),
            "completed_at": (stop or {}).get("completed_at"),
            "duration_s": _duration((start or {}).get("started_at"), (stop or {}).get("completed_at")),
            "transcript_path": (stop or {}).get("transcript_path"),
        })
    return agents


def correlate_step(agent: dict, steps: list[dict]) -> str | None:
    static = STATIC_MAP.get(agent.get("agent_type") or "")
    if static and len(static) == 1:
        return static[0]
    a_start = agent.get("started_at")
    if not a_start:
        return None
    for step in steps:
        if step.get("started_at") and step["started_at"] <= a_start and \
                (step.get("completed_at") is None or step["completed_at"] >= a_start):
            return step.get("step")
    return None


def parse_transcript(path: str) -> dict:
    p = Path(path)
    if not p.is_file():
        return {"parse_error": "transcript_not_found"}
    try:
        usage = {"model": None, "input_tokens": 0, "output_tokens": 0,
                 "cache_read_tokens": 0, "cache_creation_tokens": 0,
                 "api_calls": 0, "tool_calls": 0, "tools_used": {}}
        for rec in _read_jsonl(p):
            if rec.get("type") != "assistant" or not rec.get("message"):
                continue
            msg = rec["message"]
            usage["api_calls"] += 1
            if usage["model"] is None and msg.get("model"):
                usage["model"] = msg["model"]
            u = msg.get("usage") or {}
            usage["input_tokens"] += u.get("input_tokens") or 0
            usage["output_tokens"] += u.get("output_tokens") or 0
            usage["cache_read_tokens"] += u.get("cache_read_input_tokens") or 0
            usage["cache_creation_tokens"] += u.get("cache_creation_input_tokens") or 0
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    usage["tool_calls"] += 1
                    name = block.get("name", "?")
                    usage["tools_used"][name] = usage["tools_used"].get(name, 0) + 1
        return usage
    except OSError:
        return {"parse_error": "transcript_parse_failed"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("telemetry_dir")
    ap.add_argument("--n1-version", default="")
    ap.add_argument("--project", default="")
    args = ap.parse_args()

    telem = Path(args.telemetry_dir)
    steps_file = telem / "raw" / "steps" / f"{args.run_id}.jsonl"
    agents_file = telem / "raw" / "agents" / f"{args.run_id}.jsonl"
    out_dir = telem / "runs"
    out_dir.mkdir(parents=True, exist_ok=True)

    step_events = _read_jsonl(steps_file)
    steps = pair_steps(step_events)
    agents_raw = pair_agents(_read_jsonl(agents_file))

    agents = []
    for a in agents_raw:
        entry = {
            "agent_id": a["agent_id"], "agent_type": a["agent_type"],
            "step": correlate_step(a, steps),
            "started_at": a["started_at"], "completed_at": a["completed_at"],
            "duration_s": a["duration_s"],
            "model": None, "input_tokens": None, "output_tokens": None,
            "cache_read_tokens": None, "cache_creation_tokens": None,
            "api_calls": None, "tool_calls": None, "tools_used": None,
            "parse_error": None,
        }
        if a.get("transcript_path"):
            # Retro-fix for events recorded before the agent-stop hook learned to
            # resolve per-agent transcripts: prefer the subagent's own file when present.
            tpath = a["transcript_path"]
            if "/subagents/" not in tpath.replace("\\", "/") and a.get("agent_id"):
                candidate = Path(tpath.replace("\\\\", "\\")).with_suffix("") / "subagents" / f"agent-{a['agent_id']}.jsonl"
                if candidate.is_file():
                    tpath = str(candidate)
            parsed = parse_transcript(tpath)
            if "parse_error" in parsed and len(parsed) == 1:
                entry["parse_error"] = parsed["parse_error"]
            else:
                entry.update(parsed)
        agents.append(entry)

    envelope = {}
    for ev in step_events:
        if ev.get("layer") == "envelope":
            envelope = {**ev, **envelope}
        elif ev.get("layer") == "envelope_close":
            envelope = {**envelope, **ev}

    def _sum(vals):
        return sum(v for v in vals if v is not None)

    total_in = _sum(a["input_tokens"] for a in agents)
    total_cache = _sum(a["cache_read_tokens"] for a in agents)
    summary = {
        "total_duration_s": _sum(s["duration_s"] for s in steps),
        "total_input_tokens": total_in,
        "total_output_tokens": _sum(a["output_tokens"] for a in agents),
        "total_cache_read_tokens": total_cache,
        "cache_efficiency": round(total_cache / (total_in + total_cache), 2) if (total_in + total_cache) > 0 else 0,
        "agent_spawns": len(agents),
        "steps_completed": sum(1 for s in steps if s["outcome"] in ("pass", "skip")),
        "steps_skipped": sum(1 for s in steps if s["outcome"] == "skip"),
        "review_fix_cycles": max((s["loop_iteration"] or 0 for s in steps if s["step"] == "fix"), default=0),
        "qa_fix_cycles": sum(1 for s in steps if s["step"] == "qa" and (s["loop_iteration"] or 0) > 0),
    }

    record = {
        "schema_version": 1,
        "run_id": args.run_id,
        "session_id": envelope.get("session_id"),
        "n1_version": args.n1_version,
        "project": args.project,
        "ticket_id": envelope.get("ticket_id"),
        "branch": envelope.get("branch"),
        "started_at": envelope.get("started_at"),
        "completed_at": envelope.get("completed_at"),
        "final_outcome": envelope.get("final_outcome"),
        "estimated_tier": envelope.get("estimated_tier"),
        "config_snapshot": envelope.get("config_snapshot"),
        "steps": steps,
        "agents": agents,
        "summary": summary,
    }
    (out_dir / f"{args.run_id}.jsonl").write_text(
        json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
