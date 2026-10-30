#!/usr/bin/env python3
"""Shared accounting implementation for telemetry-merge.sh.

Pair step events, pair agent events, correlate
agents to steps (static map + temporal), parse agent transcripts for token
usage, and write the unified run record to <telemetry_dir>/runs/<run_id>.jsonl.

Stdlib only. Invoked as:
    python telemetry-merge.py <run_id> <telemetry_dir> [--n1-version V] [--project P]
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 6

STATIC_MAP = {
    "product-analyst": ["ticket"],
    "planner": ["plan"],
    "code-reviewer": ["review"],
    "security-reviewer": ["review"],
    "tech-writer": ["pr"],
}


# Orchestrator context window by model-id prefix (N1-199 F4). The transcript carries no window
# field; unknown models stay null rather than guessed.
CONTEXT_WINDOWS = {"claude-opus-5": 1_000_000, "claude-sonnet-5": 1_000_000}


def context_window_for(model: str | None) -> int | None:
    return next((size for prefix, size in CONTEXT_WINDOWS.items()
                 if model and model.startswith(prefix)), None)


def _usage(msgs: list[dict]) -> dict:
    """Token/call rollup shared by step entries, unattributed, totals and tail."""
    tools_used: dict[str, int] = {}
    for m in msgs:
        for t in m["tools"]:
            tools_used[t] = tools_used.get(t, 0) + 1
    return {
        "input_tokens": sum(m["input_tokens"] for m in msgs),
        "output_tokens": sum(m["output_tokens"] for m in msgs),
        "cache_read_tokens": sum(m["cache_read_tokens"] for m in msgs),
        "cache_creation_tokens": sum(m["cache_creation_tokens"] for m in msgs),
        "api_calls": len(msgs),
        "tool_calls": sum(len(m["tools"]) for m in msgs),
        "tools_used": tools_used,
    }


def persona_of(agent_type: str) -> str:
    """Strip the n1: namespace from an agent_type."""
    if agent_type.startswith("n1:"):
        return agent_type[len("n1:"):]
    return agent_type


def _read_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        return []
    records = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
            if isinstance(record, dict):
                records.append(record)
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
    duration = e - s
    return int(duration) if duration.is_integer() else duration


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


def repair_windows(steps: list[dict], run_start: str | None, run_end: str | None) -> list[dict]:
    """Fill a missing step bound from its chronological neighbour, else the envelope (N1-229).

    A missing start takes the previous step's end (else its start, else run_start); a missing
    end takes the next step's start (else its end, else run_end). Real timestamps are never
    overwritten; filled steps carry window_inferred so analyzers can discount them.
    """
    order = sorted((s for s in steps if s.get("started_at") or s.get("completed_at")),
                   key=lambda s: (s.get("started_at") or s.get("completed_at"))[:19])
    real = [(s.get("started_at"), s.get("completed_at")) for s in order]
    for i, s in enumerate(order):
        start, end = real[i]
        if not start:
            prev = real[i - 1] if i else (None, None)
            start = prev[1] or prev[0] or run_start
        if not end:
            nxt = real[i + 1] if i + 1 < len(real) else (None, None)
            end = nxt[0] or nxt[1] or run_end
        if start and end and start[:19] > end[:19]:
            continue  # inverted fill: leave the gap rather than invent a window
        if (start, end) != real[i]:
            s.update(started_at=start, completed_at=end,
                     duration_s=_duration(start, end), window_inferred=True)
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
    static = STATIC_MAP.get(persona_of(agent.get("agent_type") or ""))
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
        for rec in _assistant_records(_read_jsonl(p)):
            msg = rec["message"]
            usage["api_calls"] += 1
            if usage["model"] is None and msg.get("model"):
                usage["model"] = msg["model"]
            u = msg.get("usage") or {}
            if any(not isinstance(u.get(k), int) or u[k] < 0 for k in (
                    'input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')):
                return {'parse_error': 'usage_unavailable'}
            usage["input_tokens"] += u.get("input_tokens") or 0
            usage["output_tokens"] += u.get("output_tokens") or 0
            usage["cache_read_tokens"] += u.get("cache_read_input_tokens") or 0
            usage["cache_creation_tokens"] += u.get("cache_creation_input_tokens") or 0
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    usage["tool_calls"] += 1
                    name = block.get("name", "?")
                    usage["tools_used"][name] = usage["tools_used"].get(name, 0) + 1
        if not usage['api_calls']:
            return {'parse_error': 'usage_unavailable'}
        return usage
    except OSError:
        return {"parse_error": "transcript_parse_failed"}


def _assistant_records(records: list[dict]):
    # Streaming records can repeat a message ID with updated usage/content.
    # Keep the last usage and union tool blocks by ID, once per message.
    messages = {}
    for index, rec in enumerate(records):
        msg = rec.get('message')
        if rec.get('type') != 'assistant' or not isinstance(msg, dict):
            continue
        key = msg.get('id') or index
        previous = messages.get(key, {}).get('message', {})
        tools = {block.get('id'): block for block in previous.get('content', []) + (msg.get('content') or [])
                 if isinstance(block, dict) and block.get('type') == 'tool_use'}
        messages[key] = {**rec, 'message': {**msg, 'content': list(tools.values())}}
    return messages.values()


def parse_orchestrator_transcript(path: str, steps: list[dict],
                                  run_start: str | None = None, run_end: str | None = None) -> dict:
    p = Path(path)
    if not p.is_file():
        return {"steps": [], "unattributed": None, "totals": None,
                "parse_error": "orchestrator_transcript_not_found"}
    try:
        records = _read_jsonl(p)
        messages = []
        for rec in _assistant_records(records):
            msg = rec["message"]
            tools = []
            for block in msg.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") != "Agent":
                    tools.append(block.get("name", "?"))
            u = msg.get("usage") or {}
            if any(not isinstance(u.get(k), int) or u[k] < 0 for k in (
                    'input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens')):
                return {'steps': [], 'unattributed': None, 'totals': None, 'parse_error': 'usage_unavailable'}
            messages.append({
                "ts": rec["timestamp"] if isinstance(rec.get("timestamp"), str) else "",
                "input_tokens": u.get("input_tokens") or 0,
                "output_tokens": u.get("output_tokens") or 0,
                "cache_read_tokens": u.get("cache_read_input_tokens") or 0,
                "cache_creation_tokens": u.get("cache_creation_input_tokens") or 0,
                "tools": tools,
                "sidechain": bool(rec.get("isSidechain")),
                "model": msg.get("model"),
                "context": (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0)
                           + (u.get("cache_creation_input_tokens") or 0),
            })

        # finish.md begins and ends finish back to back; FINALIZE, Gate 3 and the chained
        # n1-finish run after it, so the finish window runs to the last transcript message.
        # ponytail: unbounded to the transcript end; a later manual re-merge would also absorb
        # post-run turns of the same session. Add a Stop-time bound if re-merges become routine.
        last_ts = max((m["ts"] for m in messages), default="")
        for step in steps:
            end = step.get("completed_at")
            if step.get("step") == "finish" and end and last_ts[:19] > end[:19]:
                step.update(completed_at=last_ts, window_extended=True,
                            duration_s=_duration(step.get("started_at"), last_ts))

        # Context fields describe the orchestrator's own window, so sidechain
        # (subagent) records are skipped. prev_context = context just before.
        own = sorted((m for m in messages if not m["sidechain"]), key=lambda m: m["ts"])
        for i, m in enumerate(own):
            m["prev_context"] = own[i - 1]["context"] if i else m["context"]

        # Main-transcript compact_boundary records inside the run window. Post-run
        # /compact belongs to the session, not this run.
        compactions = []
        for rec in records:
            if rec.get("type") != "system" or rec.get("subtype") != "compact_boundary" or rec.get("isSidechain"):
                continue
            ts = rec.get("timestamp")
            if not isinstance(ts, str):
                continue
            if (run_start and ts[:19] < run_start[:19]) or (run_end and ts[:19] > run_end[:19]):
                continue
            meta = rec.get("compactMetadata")
            meta = meta if isinstance(meta, dict) else {}
            compactions.append({"timestamp": ts, "trigger": meta.get("trigger") or "unknown",
                                "pre_tokens": meta.get("preTokens"), "post_tokens": meta.get("postTokens")})

        def _find_step(ts: str) -> str:
            for step in steps:
                s_start = step.get("started_at")
                s_end = step.get("completed_at")
                if s_start and s_start <= ts and (s_end is None or s_end >= ts):
                    return step.get("step", "__unattributed__")
            return "__unattributed__"

        grouped: dict[str, list] = {}
        for m in messages:
            step_name = _find_step(m["ts"])
            grouped.setdefault(step_name, []).append(m)

        step_entries = []
        unattributed = _usage([])
        for step_name, msgs in grouped.items():
            entry = {"step": step_name, **_usage(msgs)}
            if step_name == "__unattributed__":
                del entry["step"]
                unattributed = entry
            else:
                ctx = sorted((m for m in msgs if not m["sidechain"]), key=lambda m: m["ts"])
                entry.update({
                    "context_start_tokens": ctx[0]["prev_context"] if ctx else None,
                    "context_end_tokens": ctx[-1]["context"] if ctx else None,
                    "context_peak_tokens": max((m["context"] for m in ctx), default=None),
                    # Boundary timestamps carry milliseconds ("...:00.123Z") while step bounds are
                    # whole seconds, and "Z" sorts after ".", so truncate to seconds before matching.
                    "compactions": sum(1 for c in compactions
                                       if _find_step(c["timestamp"][:19] + "Z") == step_name),
                })
                step_entries.append(entry)

        if not messages:
            return {'steps': [], 'unattributed': None, 'totals': None, 'parse_error': 'usage_unavailable'}
        # Calls after the envelope close (FINALIZE, Gate 3, chained n1-finish): a named subset
        # already counted in the finish step and in totals, never added to them (N1-229).
        tail = _usage([m for m in messages if run_end and m["ts"][:19] > run_end[:19]])
        models = Counter(m["model"] for m in messages
                         if not m["sidechain"] and m["model"] and m["model"] != "<synthetic>")
        model = models.most_common(1)[0][0] if models else None
        return {"steps": step_entries, "unattributed": unattributed, "totals": _usage(messages),
                "tail": tail, "model": model, "context_window": context_window_for(model),
                "compactions": compactions, "parse_error": None}
    except OSError:
        return {"steps": [], "unattributed": None, "totals": None,
                "parse_error": "orchestrator_transcript_parse_failed"}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id")
    ap.add_argument("telemetry_dir")
    ap.add_argument("--n1-version", default="")
    ap.add_argument("--project", default="")
    ap.add_argument("--host", default="")
    args = ap.parse_args()

    telem = Path(args.telemetry_dir)
    steps_file = telem / "raw" / "steps" / f"{args.run_id}.jsonl"
    agents_file = telem / "raw" / "agents" / f"{args.run_id}.jsonl"
    out_dir = telem / "runs"
    out_dir.mkdir(parents=True, exist_ok=True)

    step_events = _read_jsonl(steps_file)
    envelope_open = {}
    for ev in step_events:
        if ev.get('layer') == 'envelope':
            envelope_open = {**ev, **envelope_open}
    envelope_close_events = [ev for ev in step_events if ev.get("layer") == "envelope_close"]
    # A later record (e.g. a genuine outcome written after a stray/incorrect
    # earlier one) reflects the true final state, so the last one wins.
    envelope_close = envelope_close_events[-1] if envelope_close_events else {}
    # The opening envelope is the run's immutable identity. A later hook may
    # add completion data, but cannot relabel the host/session it started on.
    envelope = {**envelope_close, **envelope_open}
    host = envelope.get("host") or "unknown"
    steps = repair_windows(pair_steps(step_events), envelope.get("started_at"), envelope.get("completed_at"))
    agents_raw = pair_agents(_read_jsonl(agents_file))

    agents = []
    for a in agents_raw:
        entry = {
            "agent_id": a["agent_id"], "agent_type": a["agent_type"],
            "host": host,
            "step": correlate_step(a, steps),
            "started_at": a["started_at"], "completed_at": a["completed_at"],
            "duration_s": a["duration_s"],
            "model": None, "input_tokens": None, "output_tokens": None,
            "cache_read_tokens": None, "cache_creation_tokens": None,
            "api_calls": None, "tool_calls": None, "tools_used": None,
            "parse_error": None,
            "usage_status": "unknown",
        }
        if a.get("transcript_path"):
            # Retro-fix for events recorded before the agent-stop hook learned to
            # resolve per-agent transcripts: prefer the subagent's own file when present.
            tpath = a["transcript_path"]
            if "/subagents/" not in tpath.replace("\\", "/") and a.get("agent_id"):
                candidate = Path(tpath.replace("\\\\", "\\")).with_suffix("") / "subagents" / f"agent-{a['agent_id']}.jsonl"
                if candidate.is_file():
                    tpath = str(candidate)
                else:
                    # The old hook recorded the parent for every child. Never
                    # count that same parent again when the child file is lost.
                    entry['parse_error'] = 'agent_transcript_unresolved' if Path(tpath).is_file() else 'transcript_not_found'
                    agents.append(entry)
                    continue
            parsed = parse_transcript(tpath)
            if "parse_error" in parsed and len(parsed) == 1:
                entry["parse_error"] = parsed["parse_error"]
            else:
                entry.update(parsed)
                entry["usage_status"] = "complete"
        elif not a.get("completed_at"):
            entry["parse_error"] = "agent_never_finished"
        agents.append(entry)

    session_transcript = envelope.get("session_transcript_path")
    if session_transcript is None:
        session_transcript = next((ev.get("session_transcript_path") for ev in step_events
                                   if ev.get("layer") == "session" and ev.get("session_transcript_path")), None)
    for ev in _read_jsonl(agents_file):
        if session_transcript is None and ev.get("session_transcript_path"):
            session_transcript = ev["session_transcript_path"]
            break
    if session_transcript is None:
        for a in agents_raw:
            tpath = a.get("transcript_path") or ""
            marker = "/subagents/"
            normalized = tpath.replace("\\", "/")
            if marker in normalized:
                candidate = Path(normalized.split(marker, 1)[0] + ".jsonl")
                if candidate.is_file():
                    session_transcript = str(candidate)
                    break

    orchestrator = None
    if session_transcript and host == 'claude-code':
        orchestrator = parse_orchestrator_transcript(session_transcript, steps,
                                                     envelope.get("started_at"), envelope.get("completed_at"))
    if orchestrator is not None:
        orchestrator["transcript_path"] = session_transcript

    def _sum(vals):
        return sum(v for v in vals if v is not None)

    compactions = (orchestrator or {}).get("compactions")  # None = transcript not parsed (unknown, not 0)
    decisions = [e for e in step_events if e.get('event') == 'decision']
    questions = [e for e in step_events if e.get('event') == 'question']
    outcomes = [e for e in step_events if e.get('event') == 'outcome']
    dict_outcomes = [o for o in outcomes if isinstance(o.get("outcomes"), dict)]
    def _outcome_max(key):
        # Outcome values are strings; None = no outcome reported (unknown, not 0)
        vals = []
        for o in dict_outcomes:
            s = str(o["outcomes"].get(key, ""))
            if s.isascii() and s.isdigit():
                vals.append(int(s))
        return max(vals) if vals else None
    total_in = _sum(a["input_tokens"] for a in agents)
    total_cache = _sum(a["cache_read_tokens"] for a in agents)
    orch_totals = (orchestrator or {}).get("totals")
    summary = {
        "total_duration_s": _duration(envelope.get("started_at"), envelope.get("completed_at")),
        "total_step_duration_s": _sum(s["duration_s"] for s in steps) if any(s["duration_s"] is not None for s in steps) else None,
        "total_input_tokens": total_in,
        "total_output_tokens": _sum(a["output_tokens"] for a in agents),
        "total_cache_read_tokens": total_cache,
        "total_cache_creation_tokens": _sum(a["cache_creation_tokens"] for a in agents),
        "cache_efficiency": round(total_cache / (total_in + total_cache), 2) if (total_in + total_cache) > 0 else 0,
        "agent_spawns": len(agents),
        "steps_completed": sum(1 for s in steps if s["outcome"] in ("pass", "skip", "success", "skipped")),
        "steps_skipped": sum(1 for s in steps if s["outcome"] in ("skip", "skipped")),
        "review_fix_cycles": _outcome_max("review_fix_cycles"),
        "qa_fix_cycles": _outcome_max("qa_fix_cycles"),
        "review_blocking_count": next((int(o["outcomes"].get("review_blocking_count", 0)) for o in dict_outcomes), None),
        "break_check_verdict": next((o["outcomes"].get("break_check_verdict") for o in dict_outcomes), None),
        "decision_count": len(decisions),
        "compaction_count": len(compactions) if compactions is not None else None,
        "compaction_auto_count": sum(c["trigger"] == "auto" for c in compactions) if compactions is not None else None,
        "compaction_manual_count": sum(c["trigger"] == "manual" for c in compactions) if compactions is not None else None,
        "compaction_timestamps": [c["timestamp"] for c in compactions] if compactions is not None else None,
        "orchestrator_input_tokens": orch_totals["input_tokens"] if orch_totals else None,
        "orchestrator_output_tokens": orch_totals["output_tokens"] if orch_totals else None,
        "orchestrator_tool_calls": orch_totals["tool_calls"] if orch_totals else None,
    }

    # Determine usage scope and status
    any_parsed = any(a.get("input_tokens") is not None for a in agents)
    usage_scope = "per-agent"
    usage_status = "complete" if any_parsed else "unknown"

    record = {
        "schema_version": SCHEMA_VERSION,
        "run_id": args.run_id,
        "session_id": envelope.get("session_id"),
        "session_transcript_path": session_transcript,
        "n1_version": envelope.get('n1_version') or args.n1_version,
        "project": args.project,
        "host": host,
        "cli_version": None,
        "parser_schema_version": SCHEMA_VERSION,
        "usage_status": usage_status,
        "usage_scope": usage_scope,
        "ticket_id": envelope.get("ticket_id"),
        "branch": envelope.get("branch"),
        "started_at": envelope.get("started_at"),
        "completed_at": envelope.get("completed_at"),
        "final_outcome": envelope.get("final_outcome"),
        "estimated_tier": envelope.get("estimated_tier"),
        "config_snapshot": envelope.get("config_snapshot"),
        "orchestrator": orchestrator,
        "steps": steps,
        "agents": agents,
        "decisions": decisions,
        "questions": questions,
        "outcomes": outcomes,
        "summary": summary,
    }

    # Comparable totals: input includes fresh, cached-read and cached-write input.
    # Reasoning is already included in output.
    if host == 'claude-code':
        components = [orch_totals, *agents]
        fields = ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens')
        for field in fields:
            values = [(component or {}).get(field) for component in components]
            summary['total_' + field] = sum(values) if all(isinstance(v, (int, float)) for v in values) else None
        input_parts = [summary['total_' + field] for field in ('input_tokens', 'cache_read_tokens', 'cache_creation_tokens')]
        summary['total_uncached_input_tokens'] = summary['total_input_tokens']
        summary['total_input_tokens'] = sum(input_parts) if all(v is not None for v in input_parts) else None
        record['usage_scope'] = 'session-tree' if orch_totals else 'per-agent'
        record['usage_status'] = 'complete' if all(summary['total_' + f] is not None for f in fields) else (
            'partial' if orch_totals or any(a.get('input_tokens') is not None for a in agents) else 'unknown')
    else:
        for field in ('input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens', 'reasoning_tokens'):
            summary['total_' + field] = None
        record['usage_status'] = 'unknown'
    values = [summary['total_input_tokens'], summary['total_output_tokens']]
    summary['total_tokens'] = sum(values) if all(v is not None for v in values) else None
    total_in = summary['total_input_tokens']
    total_cache = summary['total_cache_read_tokens']
    summary['cache_efficiency'] = round(total_cache / total_in, 2) if total_in and total_cache is not None else None
    record['usage_coverage'] = {'headless_coverage': 'unknown', 'discovery_status': 'hook-recorded'}
    record['root_usage'] = orch_totals

    output = out_dir / f"{args.run_id}.jsonl"
    temporary = out_dir / f".{args.run_id}.{os.getpid()}.tmp"
    temporary.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
    temporary.replace(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
