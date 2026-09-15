<!-- Purpose: Analysis sections 4-6, brainstorm context-contribution analysis, local testing effectiveness, output format. -->

## Analysis: Section 4 — Token Usage Summary

If agent token data is available in run records:
- Total tokens per run (avg, p50, p90)
- Tokens saved by downgrades (estimated: difference between frontier and downgraded model costs)
- Orchestrator output tokens (avg per type)
- Cache creation tokens per run (avg, p50, p90) — from `summary.total_cache_creation_tokens` (field added in v3.8.0; treat absence as 0 for older records)
- Cache creation share: `total_cache_creation_tokens / (total_input_tokens + total_cache_read_tokens + total_cache_creation_tokens)` — indicates how much of the token budget goes to populating the cache vs actual input

## Analysis: Section 5 — Compaction Events

If compaction data is available in run records (`summary.compaction_count > 0`):
- Runs with compaction: N out of total (X%)
- Average compaction count per affected run
- Compaction timing: correlate `compaction_timestamps` with step start/end times to determine which step was running when compaction fired
- Trend: is compaction frequency increasing/decreasing across recent runs?

| Step at compaction | Count | % of compactions |
|-------------------|-------|-----------------|
| review | N | X% |
| local-testing | N | X% |
| ... | ... | ... |

## Analysis: Section 6 — Question Quality

If question events are available in run records (`questions` array non-empty):

**Questions per run:**
- Total questions per run: avg, p50, p90
- Brainstorm questions per run: avg (target: below 0.5 after two weeks)
- Trend: is questions/run decreasing across recent versions?

| Step | Questions/run (avg) | Asked | Auto-decided | Decide-for-me | Inherited |
|------|---------------------|-------|--------------|---------------|-----------|
| analysis | X | N | N | N | N |
| brainstorm | X | N | N | N | N |
| fix | X | N | N | N | N |
| ... | ... | ... | ... | ... | ... |

**Resolution distribution:**
- Recommended-followed share: X% (questions resolved as auto-decided / total)
- Decide-for-me share: X% (questions resolved via decide-for-me / total)
- Inherited share: X% (questions inherited from parent story / total)
- Asked share: X% (questions escalated to user / total)

**Earned autonomy line:**
For each project with >= 20 runs, compute a rolling 10-run average of questions/run. If the trend is monotonically decreasing over the last 3 data points AND the current average is below 1.0, report: "Project <name> has earned autonomy -- consider tightening escalation thresholds."

If no question events are found across any runs, report: "No question telemetry data found. Question events are emitted starting from v2.90.0."

## Brainstorm Context-Contribution Analysis

**Purpose:** Attribute compaction events to the brainstorm step across runs to decide whether Stage 2 (subagent brainstormer) is worth implementing.

**Procedure:**

1. For each run JSONL file, extract two event streams:
   - `step` events for `"step":"brainstorm"`: note `started_at` and `completed_at` timestamps.
   - `compaction` events: note `timestamp`.

2. For each compaction event, classify which step was active when it fired:
   - A compaction belongs to `brainstorm` if its `timestamp` falls between the brainstorm `started_at` and `completed_at`.
   - Repeat for all other steps (analysis, plan, review, etc.).

3. Aggregate across all runs:

| Step | Compaction count | % of all compactions | Runs affected |
|------|-----------------|----------------------|---------------|
| brainstorm | N | X% | M |
| review | N | X% | M |
| ... | ... | ... | ... |

4. Report average brainstorm duration for runs that compacted vs. those that did not. A large duration gap corroborates that brainstorm is a dominant context consumer.

**Stage 2 go/no-go criterion:** Proceed to Stage 2 (subagent brainstormer) only if ALL of:
- Brainstorm accounts for ≥ 40% of all compaction events across runs with compaction, AND
- At least 10 runs with completed brainstorm telemetry are available (sufficient sample), AND
- No other single step accounts for a higher share (brainstorm is the dominant sink, not just large).

If the data shows brainstorm is not the dominant compaction source, Stage 2 is not justified — investigate the actual dominant step instead.

**Note:** This procedure requires `telemetry.enabled: true` in config and at least one full pipeline run that produced `started_at`/`completed_at` step events for `brainstorm`. If brainstorm step events are missing, the compaction-to-step attribution cannot be performed.

## Local Testing Effectiveness

Aggregate `local-testing` step events across all runs to characterize how local testing is being used. A run contributes to this section only when its `local-testing` step event has a non-empty `metadata` field (runs before v2.97.0 may have empty metadata — include them in counts but exclude from rate calculations).

### Action-Type Distribution

Count runs by `action_type` value:

| action_type | Count | % of local-testing runs |
|-------------|-------|------------------------|
| live | N | X% |
| test_only | N | X% |
| skipped | N | X% |

`skipped` runs carry `{"skip_reason":"qa_dedup"}` in metadata (pre-v2.97.0 skip path) or `{"action_type":"skipped"}` (v2.97.0+). Count both forms as `skipped`. Include auto-skip runs (documentation-only changes, no testable scenarios) in the `skipped` bucket as well.

### Infrastructure Start Rate

Across non-skipped runs with metadata:
- Runs where `infra_started: true`: N (X%)
- Runs where `infra_started: false` (test_only): N (X%)

A high `test_only` rate indicates projects where infrastructure is consistently unavailable or not needed. A high `live` rate indicates projects with real integration testing.

### Common Services and Scenario Types

**Top services started** (from `services[]` across all `live` runs):

| Service | Runs | % of live runs |
|---------|------|----------------|
| postgres | N | X% |
| redis | N | X% |
| ... | ... | ... |

**Scenario type distribution** (from `scenario_types[]` across non-skipped runs):

| Type | Runs | % of non-skipped runs |
|------|------|-----------------------|
| curl | N | X% |
| CLI | N | X% |
| browser | N | X% |

### QA Overlap

Across runs with `qa_overlap_pct` not null:
- Average qa_overlap_pct: X%
- p50: X%, p90: X%
- Runs with 0% overlap (fully complementary to QA): N (X%)
- Runs with >50% overlap (mostly duplicating QA): N (X%)

A low average overlap confirms local testing is complementary to the QA step rather than redundant. A high overlap may indicate the QA dedup gate threshold needs tuning.

Runs with `qa_overlap_pct: null` (no QA runner commands found or pre-v2.97.0): excluded from this calculation — note count separately.

**Backward compatibility:** Runs emitted before v2.97.0 have `metadata: {}` for the local-testing step. Report them as "legacy runs (no metadata)" and exclude them from all rate calculations above.

## Output Format

Present the full report as markdown. End with:

```
## Recommended Config Changes

<list of specific threshold changes, or "No changes recommended — all thresholds well-calibrated">
```

This is NOT auto-tuning. The report is for human review — config changes are manual.
