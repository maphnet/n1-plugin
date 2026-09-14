<!-- Purpose: Data collection and aggregation, analysis sections 1-3 (decision summary, correlation, thresholds). -->

## Data Collection

Scan all run records across projects:

```bash
RUNS=$(find "${N1_HOME}/memory" -path "*/telemetry/runs/*.jsonl" -type f 2>/dev/null)
```

If no run records found, report: "No telemetry data found. Run some tasks with `telemetry.enabled: true` to generate data." and stop.

For each JSONL file, read all lines and parse:
- `decision` events: `{"event":"decision","step":"...","action":"skip|downgrade|escalate","reason":"...","signals":{...}}` — historical only: emitted by runs before v2.76.0; current runs no longer produce them
- `outcome` events: `{"event":"outcome","outcomes":{"review_pass_first_try":"true|false","qa_pass_first_try":"true|false","fix_cycles_count":"N"}}`
- `step_start`/`step_end` events: for duration calculation

## Analysis: Section 1 — Decision Summary

Count decisions by action type:

| Action | Count | Most common step | Most common reason |
|--------|-------|-----------------|-------------------|
| skip | N | brainstorm | has_bug_root_cause + bug type |
| downgrade | N | code-reviewer | low blast_radius + few lines |
| escalate | N | qa-engineer | complex + broken tests |

## Analysis: Section 2 — Decision-Outcome Correlation

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

## Analysis: Section 3 — Threshold Recommendations

**Paired-run floor.** A recommendation for a decision id is allowed only when at least `telemetry.minPairedRuns` runs (config, default `100`) contain both a `decisions[]` entry with that id and an `outcomes[]` entry with `review_blocking_count`. Below the floor, print the row with `Recommendation: insufficient data (N/100 paired runs)` and never propose a threshold change. Print the paired-run count next to every number in this section; a median over 6 runs and over 120 runs are different claims.

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
- If threshold rarely triggers (<10% of runs) AND the floor is met: recommend **loosen** (threshold is too conservative)
- If insufficient data (<5 runs with this decision): report "insufficient data"
