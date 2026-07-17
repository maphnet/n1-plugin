---
name: n1-telemetry
description: "Analyze optimization decision telemetry. Correlates signal-driven decisions (skip/downgrade/escalate) with quality outcomes (review pass rate, fix cycles) and produces threshold calibration recommendations."
argument-hint: "[--project <path>]"
model: sonnet
effort: medium
---

# N1 Telemetry Analysis

Aggregate decision-to-outcome correlations across pipeline runs and produce threshold calibration recommendations.

**Announce at start:** "I'm using the n1-telemetry skill to analyze optimization decisions."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty, tell the user N1 is not configured and stop.

## Data Collection

Scan all run records across projects:

```bash
RUNS=$(find "${N1_HOME}/memory" -path "*/telemetry/runs/*.jsonl" -type f 2>/dev/null)
```

If no run records found, report: "No telemetry data found. Run some tasks with `telemetry.enabled: true` to generate data." and stop.

For each JSONL file, read all lines and parse:
- `decision` events: `{"event":"decision","step":"...","action":"skip|downgrade|escalate","reason":"...","signals":{...}}`
- `outcome` events: `{"event":"outcome","outcomes":{"review_pass_first_try":"true|false","qa_pass_first_try":"true|false","fix_cycles_count":"N"}}`
- `step_start`/`step_end` events: for duration calculation

## Analysis

### 1. Decision Summary

Count decisions by action type:

| Action | Count | Most common step | Most common reason |
|--------|-------|-----------------|-------------------|
| skip | N | brainstorm | has_bug_root_cause + bug type |
| downgrade | N | code-reviewer | low blast_radius + few lines |
| escalate | N | qa-engineer | complex + broken tests |

### 2. Decision-Outcome Correlation

For each decision type, correlate with quality outcomes:

**Skip decisions:**
- When brainstorm was skipped: review pass rate = X% (vs Y% when not skipped)
- When plan was skipped: fix cycle count avg = X (vs Y when not skipped)
- When plan-review was skipped: review pass rate = X%

**Downgrade decisions:**
- When code-reviewer was downgraded: review pass rate = X%, fix cycles avg = X
- When solution-architect was downgraded: any measurable quality difference?

**Escalation decisions:**
- When qa-engineer was escalated: qa pass rate change

### 3. Threshold Recommendations

For each threshold in the system, report:

| Threshold | Current value | Hit rate | Outcome when triggered | Recommendation |
|-----------|--------------|----------|----------------------|----------------|
| `files_changed < 3` for plan skip | < 3 | X% of runs | review pass: Y% | keep / tighten / loosen |
| `lines_changed < 50` for reviewer downgrade | < 50 | X% | review pass: Y% | keep / tighten / loosen |
| `blast_radius: low` for security skip | low | X% | (manual check) | keep / tighten |
| `design_clarity: high` for plan skip | high | X% | fix cycles: Y | keep / tighten / loosen |

**Recommendation logic:**
- If outcome is WORSE when threshold triggers: recommend **tighten** (make harder to trigger)
- If outcome is SAME or BETTER: recommend **keep** (threshold is well-calibrated)
- If threshold rarely triggers (<10% of runs): recommend **loosen** (threshold is too conservative)
- If insufficient data (<5 runs with this decision): report "insufficient data"

### 4. Token Usage Summary

If agent token data is available in run records:
- Total tokens per run (avg, p50, p90)
- Tokens saved by downgrades (estimated: difference between frontier and downgraded model costs)
- Orchestrator output tokens (avg per type)

## Output Format

Present the full report as markdown. End with:

```
## Recommended Config Changes

<list of specific threshold changes, or "No changes recommended — all thresholds well-calibrated">
```

This is NOT auto-tuning. The report is for human review — config changes are manual.
