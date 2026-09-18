#!/usr/bin/env python3
"""N1 telemetry analyzer.

Iterates recent merged telemetry run records across all N1 projects,
extracts per-run performance metrics, detects anomalies, and computes
cross-run aggregations. Persists reports as JSON.

Usage:
  python3 scripts/telemetry_analyzer.py collect [--n1-root DIR] [--last N] [--projects P1,P2] [--deep] [--out FILE]

The script never calls a model. All analysis is deterministic.
Read-only with respect to ~/.n1/<project>/ and ~/.claude/projects/.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import statistics
import sys
from pathlib import Path

# ---------------------------------------------------------------- constants

DEFAULT_LAST = 20

ANOMALY_THRESHOLDS = {
    "step_duration_s": 300,       # 5 minutes
    "agent_input_tokens": 100_000,
    "cache_efficiency": 0.5,
    "fix_cycles": 3,
}

BASH_CMD_PREFIXES = {
    "git", "npm", "npx", "node", "python3", "python", "pip", "uv",
    "find", "ls", "cat", "grep", "rg", "sed", "awk", "curl", "wget",
    "docker", "docker-compose", "make", "cargo", "go", "java", "mvn",
    "gradle", "dotnet", "ruby", "gem", "bundle", "bash", "sh", "cd",
    "mkdir", "rm", "cp", "mv", "chmod", "chown", "tar", "unzip",
    "jq", "yq", "terraform", "kubectl", "helm", "aws", "az", "gcloud",
    "pytest", "jest", "vitest", "mocha",
}


# ---------------------------------------------------------------- benchmark imports

def _import_benchmark():
    """Import read_jsonl and load_runs from the sibling benchmark.py."""
    script_dir = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "benchmark", script_dir / "benchmark.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

_bm = _import_benchmark()
read_jsonl = _bm.read_jsonl
load_runs = _bm.load_runs
parse_ts = _bm.parse_ts


# ---------------------------------------------------------------- argument parsing

def build_parser():
    p = argparse.ArgumentParser(description="N1 telemetry analyzer")
    sub = p.add_subparsers(dest="command")

    collect = sub.add_parser("collect", help="Collect and analyze recent runs")
    collect.add_argument("--n1-root", default=os.path.expanduser("~/.n1"),
                         help="Root directory containing N1 project dirs (default: ~/.n1)")
    collect.add_argument("--last", type=int, default=DEFAULT_LAST,
                         help=f"Number of most recent runs to analyze (default: {DEFAULT_LAST})")
    collect.add_argument("--projects", type=str, default=None,
                         help="Comma-separated list of project slugs to include (default: all)")
    collect.add_argument("--deep", action="store_true",
                         help="Parse transcripts for Bash command subtype classification")
    collect.add_argument("--out", type=str, default=None,
                         help="Output file path (default: stdout + $N1_HOME/reports/)")
    return p


# ---------------------------------------------------------------- filtering & selection

def project_slug_from_run(run: dict) -> str | None:
    """Extract the project slug from a run's source path.

    Source paths follow: <n1_root>/<project>/memory/<ticket>/telemetry/runs/<file>.
    The project slug is the first directory component after n1_root.
    """
    src = run.get("_source_path", "")
    if not src:
        return None
    # Pattern: .../<project>/memory/<ticket>/telemetry/runs/<file>
    parts = Path(src).parts
    try:
        mem_idx = parts.index("memory")
        if mem_idx >= 1:
            return parts[mem_idx - 1]
    except (ValueError, IndexError):
        pass
    return None


def ticket_id_from_run(run: dict) -> str | None:
    """Extract ticket ID from run source path."""
    src = run.get("_source_path", "")
    if not src:
        return None
    parts = Path(src).parts
    try:
        mem_idx = parts.index("memory")
        if mem_idx + 1 < len(parts):
            return parts[mem_idx + 1]
    except (ValueError, IndexError):
        pass
    return None


def filter_and_select(runs: list[dict], last: int,
                      projects: list[str] | None) -> list[dict]:
    """Filter by project slugs, sort by started_at descending, take last N."""
    if projects:
        proj_set = {p.lower() for p in projects}
        runs = [r for r in runs if (project_slug_from_run(r) or "").lower() in proj_set]

    # Sort by started_at descending (most recent first)
    def sort_key(r):
        ts = parse_ts(r.get("started_at"))
        return ts if ts is not None else 0
    runs.sort(key=sort_key, reverse=True)

    return runs[:last]


# ---------------------------------------------------------------- per-run extraction

def extract_steps(run: dict) -> list[dict]:
    """Extract step metrics from a merged run record."""
    raw_steps = run.get("steps") or []
    steps = []
    for s in raw_steps:
        step = {
            "name": s.get("step", "unknown"),
            "step_number": s.get("step_number"),
            "duration_s": s.get("duration_s"),
            "outcome": s.get("outcome", "unknown"),
        }
        # Get tools from orchestrator breakdown if available
        # orchestrator.steps is a list of dicts, each with a "step" key
        orch = run.get("orchestrator") or {}
        orch_steps = orch.get("steps") or []
        orch_step = {}
        for os_entry in (orch_steps if isinstance(orch_steps, list) else []):
            if os_entry.get("step") == step["name"]:
                orch_step = os_entry
                break
        step["tools"] = orch_step.get("tools_used") or {}
        step["tokens"] = {
            "input": orch_step.get("input_tokens", 0),
            "output": orch_step.get("output_tokens", 0),
        }
        steps.append(step)
    return steps


def extract_agents(run: dict) -> list[dict]:
    """Extract agent metrics from a merged run record."""
    raw_agents = run.get("agents") or []
    agents = []
    for a in raw_agents:
        is_codex = a.get("usage_status") == "unknown"
        agent = {
            "type": a.get("agent_type", "unknown"),
            "step": a.get("step", "unknown"),
            "duration_s": a.get("duration_s"),
            "model": a.get("model"),
        }
        if is_codex:
            agent["tokens"] = "N/A"
            agent["usage_status"] = "unknown"
        else:
            agent["tokens"] = {
                "input": a.get("input_tokens", 0),
                "output": a.get("output_tokens", 0),
                "cache_read": a.get("cache_read_tokens", 0),
            }
        agent["tool_calls"] = a.get("tool_calls", 0)
        agent["tools"] = a.get("tools_used") or {}
        agents.append(agent)
    return agents


def extract_totals(run: dict) -> dict:
    """Extract summary totals from a merged run record.

    The summary uses flat keys (total_input_tokens, total_output_tokens, etc.)
    not a nested "totals" dict. Orchestrator totals are in orchestrator.totals.
    """
    summary = run.get("summary") or {}

    # Agent and orchestrator tools_used are from separate transcripts
    # (agent sessions vs orchestrator session), so summing is correct.
    web_searches = 0
    for a in (run.get("agents") or []):
        tools = a.get("tools_used") or {}
        web_searches += tools.get("WebSearch", 0)
    # Orchestrator steps (list of dicts) and unattributed
    orch = run.get("orchestrator") or {}
    for step_data in (orch.get("steps") or []):
        if isinstance(step_data, dict):
            tools = step_data.get("tools_used") or {}
            web_searches += tools.get("WebSearch", 0)
    unattr = orch.get("unattributed") or {}
    web_searches += (unattr.get("tools_used") or {}).get("WebSearch", 0)

    return {
        "input_tokens": summary.get("total_input_tokens"),
        "usage_status": run.get("usage_status", "unknown"),
        "usage_scope": run.get("usage_scope", "unknown"),
        "parser_schema_version": run.get("parser_schema_version"),
        "usage_coverage": run.get("usage_coverage"),
        "output_tokens": summary.get("total_output_tokens"),
        "cache_read_tokens": summary.get("total_cache_read_tokens"),
        "cache_efficiency": summary.get("cache_efficiency"),
        "tool_calls": summary.get("orchestrator_tool_calls"),
        "web_searches": web_searches,
        "agent_spawns": summary.get("agent_spawns", len(run.get("agents") or [])),
    }


def compute_duration(run: dict) -> float | None:
    """Compute total run duration in seconds."""
    started = parse_ts(run.get("started_at"))
    completed = parse_ts(run.get("completed_at"))
    if started and completed:
        return round(completed - started, 1)
    return None


def extract_run_report(run: dict) -> dict:
    """Build a complete per-run report object."""
    # Count fix cycles from outcomes
    fix_cycles = 0
    for o in (run.get("outcomes") or []):
        oc = o.get("outcomes") or {}
        fc = oc.get("fix_cycles_count")
        if fc is not None:
            try:
                fix_cycles = max(fix_cycles, int(fc))
            except (ValueError, TypeError):
                pass

    return {
        "run_id": run.get("run_id"),
        "ticket_id": ticket_id_from_run(run),
        "project": project_slug_from_run(run),
        "n1_version": run.get("n1_version"),
        "tier": run.get("estimated_tier"),
        "started_at": run.get("started_at"),
        "total_duration_s": compute_duration(run),
        "total_step_duration_s": (run.get('summary') or {}).get('total_step_duration_s'),
        "final_outcome": run.get("final_outcome"),
        "fix_cycles": fix_cycles,
        "steps": extract_steps(run),
        "agents": extract_agents(run),
        "totals": extract_totals(run),
    }


# ---------------------------------------------------------------- anomaly detection

def detect_anomalies(report: dict) -> list[dict]:
    """Flag anomalies in a run report based on threshold values."""
    anomalies = []

    # Slow steps
    for s in report.get("steps", []):
        dur = s.get("duration_s")
        if dur is not None and dur > ANOMALY_THRESHOLDS["step_duration_s"]:
            anomalies.append({
                "type": "slow_step",
                "step": s["name"],
                "value": dur,
                "threshold": ANOMALY_THRESHOLDS["step_duration_s"],
                "message": f"Step '{s['name']}' took {dur:.0f}s (threshold: {ANOMALY_THRESHOLDS['step_duration_s']}s)",
            })

    # Token-heavy agents
    for a in report.get("agents", []):
        tokens = a.get("tokens")
        if isinstance(tokens, dict):
            inp = tokens.get("input") or 0
            if inp > ANOMALY_THRESHOLDS["agent_input_tokens"]:
                anomalies.append({
                    "type": "token_heavy_agent",
                    "agent": a["type"],
                    "step": a.get("step"),
                    "value": inp,
                    "threshold": ANOMALY_THRESHOLDS["agent_input_tokens"],
                    "message": f"Agent '{a['type']}' in '{a.get('step')}' used {inp:,} input tokens (threshold: {ANOMALY_THRESHOLDS['agent_input_tokens']:,})",
                })

    # Low cache efficiency
    cache_eff = report.get("totals", {}).get("cache_efficiency")
    if cache_eff is not None and cache_eff < ANOMALY_THRESHOLDS["cache_efficiency"]:
        anomalies.append({
            "type": "low_cache_efficiency",
            "value": cache_eff,
            "threshold": ANOMALY_THRESHOLDS["cache_efficiency"],
            "message": f"Cache efficiency {cache_eff:.1%} below {ANOMALY_THRESHOLDS['cache_efficiency']:.0%} threshold",
        })

    # Excessive fix cycles
    fc = report.get("fix_cycles", 0)
    if fc > ANOMALY_THRESHOLDS["fix_cycles"]:
        anomalies.append({
            "type": "excessive_fix_cycles",
            "value": fc,
            "threshold": ANOMALY_THRESHOLDS["fix_cycles"],
            "message": f"Fix cycles: {fc} (threshold: {ANOMALY_THRESHOLDS['fix_cycles']})",
        })

    return anomalies


# ---------------------------------------------------------------- cross-run aggregation

def percentile(values: list[float], p: float) -> float | None:
    """Compute the p-th percentile (0-100) of a list of values."""
    if not values:
        return None
    sorted_v = sorted(values)
    k = (len(sorted_v) - 1) * (p / 100)
    f = int(k)
    c = f + 1
    if c >= len(sorted_v):
        return sorted_v[f]
    return sorted_v[f] + (k - f) * (sorted_v[c] - sorted_v[f])


def aggregate_runs(reports: list[dict]) -> dict:
    """Compute cross-run summary statistics grouped by tier and step."""
    # Per-tier aggregation
    by_tier: dict[str, list[dict]] = {}
    for r in reports:
        tier = r.get("tier") or "unknown"
        by_tier.setdefault(tier, []).append(r)

    tier_stats = {}
    for tier, tier_reports in by_tier.items():
        durations = [r["total_duration_s"] for r in tier_reports
                     if r.get("total_duration_s") is not None]
        input_tokens = [r["totals"]["input_tokens"] for r in tier_reports
                        if r.get("totals", {}).get("input_tokens") is not None]
        tool_calls = [r["totals"]["tool_calls"] for r in tier_reports
                      if r.get("totals", {}).get("tool_calls") is not None]
        cache_effs = [r["totals"]["cache_efficiency"] for r in tier_reports
                      if r.get("totals", {}).get("cache_efficiency") is not None]
        agent_counts = [r["totals"]["agent_spawns"] for r in tier_reports]

        tier_stats[tier] = {
            "count": len(tier_reports),
            "duration": _stat_block(durations),
            "input_tokens": _stat_block(input_tokens),
            "tool_calls": _stat_block(tool_calls),
            "cache_efficiency": _stat_block(cache_effs),
            "agent_spawns": _stat_block(agent_counts),
        }

    # Per-step aggregation (across all runs)
    step_durations: dict[str, list[float]] = {}
    step_tokens: dict[str, list[int]] = {}
    for r in reports:
        for s in r.get("steps", []):
            name = s.get("name", "unknown")
            if s.get("duration_s") is not None:
                step_durations.setdefault(name, []).append(s["duration_s"])
            tokens_in = s.get("tokens", {}).get("input", 0)
            if tokens_in is not None:
                step_tokens.setdefault(name, []).append(tokens_in)

    step_stats = {}
    for name in sorted(set(list(step_durations.keys()) + list(step_tokens.keys()))):
        step_stats[name] = {
            "duration": _stat_block(step_durations.get(name, [])),
            "input_tokens": _stat_block(step_tokens.get(name, [])),
        }

    # Anomaly summary
    total_anomalies = 0
    anomaly_type_counts: dict[str, int] = {}
    for r in reports:
        for a in r.get("anomalies", []):
            total_anomalies += 1
            anomaly_type_counts[a["type"]] = anomaly_type_counts.get(a["type"], 0) + 1

    return {
        "total_runs": len(reports),
        "by_tier": tier_stats,
        "by_step": step_stats,
        "anomaly_summary": {
            "total": total_anomalies,
            "by_type": anomaly_type_counts,
        },
    }


def _stat_block(values: list[float | int]) -> dict:
    """Compute avg, median, p90, min, max for a list of numeric values."""
    if not values:
        return {"count": 0, "avg": None, "median": None, "p90": None, "min": None, "max": None}
    return {
        "count": len(values),
        "avg": round(statistics.mean(values), 1),
        "median": round(statistics.median(values), 1),
        "p90": round(percentile(values, 90), 1),
        "min": round(min(values), 1),
        "max": round(max(values), 1),
    }


# ---------------------------------------------------------------- deep mode: Bash subtypes

def classify_bash_command(command: str) -> str:
    """Extract the leading command word from a shell command string."""
    if not command or not isinstance(command, str):
        return "other"
    # Strip leading env vars, sudo, nice, etc.
    cmd = command.strip()
    changed = True
    while changed:
        changed = False
        for prefix in ("sudo ", "nice ", "nohup ", "env "):
            if cmd.startswith(prefix):
                cmd = cmd[len(prefix):]
                changed = True
    # Get the first word
    word = cmd.split()[0] if cmd.split() else "other"
    # Strip path prefix (e.g., /usr/bin/git -> git)
    word = word.rsplit("/", 1)[-1]
    return word if word in BASH_CMD_PREFIXES else "other"


def extract_bash_subtypes_from_transcript(transcript_path: str) -> dict[str, int]:
    """Parse a Claude Code transcript JSONL and classify Bash commands by subtype.

    Returns a dict of {command_prefix: count}.
    """
    counts: dict[str, int] = {}
    path = Path(transcript_path)
    if not path.is_file():
        return counts

    for rec, _ in read_jsonl(path):
        if not rec or rec.get("type") != "assistant":
            continue
        content = (rec.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue
            if item.get("name") != "Bash":
                continue
            inp = item.get("input") or {}
            command = inp.get("command", "")
            subtype = classify_bash_command(command)
            counts[subtype] = counts.get(subtype, 0) + 1

    return counts


def enrich_with_deep(report: dict, run: dict) -> None:
    """Add Bash command subtypes to agents and steps in a report (mutates report)."""
    transcript_path = run.get("session_transcript_path")
    if not transcript_path or not Path(transcript_path).is_file():
        report["deep_status"] = "transcript_unavailable"
        return

    bash_subtypes = extract_bash_subtypes_from_transcript(transcript_path)
    report["bash_commands"] = bash_subtypes
    report["deep_status"] = "enriched"


# ---------------------------------------------------------------- collect command

def cmd_collect(args):
    """Load runs, extract metrics, detect anomalies, aggregate, and output."""
    n1_root = Path(args.n1_root)
    if not n1_root.is_dir():
        print(json.dumps({"error": f"N1 root not found: {n1_root}"}), file=sys.stderr)
        sys.exit(1)

    # Load all runs
    runs, malformed = load_runs(n1_root)
    if not runs:
        print(json.dumps({"error": "No telemetry runs found", "malformed_lines": malformed}))
        sys.exit(0)

    # Parse project filter
    projects = None
    if args.projects:
        projects = [p.strip() for p in args.projects.split(",") if p.strip()]

    # Filter and select
    selected = filter_and_select(runs, args.last, projects)
    if not selected:
        print(json.dumps({"error": "No runs match the filter criteria",
                          "total_runs": len(runs), "malformed_lines": malformed}))
        sys.exit(0)

    # Extract per-run reports
    reports = []
    for run in selected:
        report = extract_run_report(run)
        report["anomalies"] = detect_anomalies(report)
        if args.deep:
            enrich_with_deep(report, run)
        reports.append(report)

    # Cross-run aggregation
    aggregation = aggregate_runs(reports)

    result = {
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_available_runs": len(runs),
        "analyzed_runs": len(reports),
        "malformed_lines": malformed,
        "deep_mode": args.deep,
        "aggregation": aggregation,
        "runs": reports,
    }

    output = json.dumps(result, indent=2, default=str)

    # Persist to file if --out specified
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(output, encoding="utf-8")
        print(f"Report written to {out_path}", file=sys.stderr)

    # Always write to stdout for the skill to consume
    print(output)


# ---------------------------------------------------------------- main

def main():
    parser = build_parser()
    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)
    if args.command == "collect":
        cmd_collect(args)


if __name__ == "__main__":
    main()
