### Telemetry

Optional local-first telemetry gated on `telemetry.enabled` in `$N1_HOME/config.json` (default `false`). When enabled, captures per-step timing, per-agent performance, and token consumption for offline efficiency analysis.

**Two-layer collection:**

| Layer | Source | Captures |
|-------|--------|----------|
| Orchestrator markers | `date -u` calls at step boundaries in `n1-start` | Step name, timing, outcome, loop counts |
| Hooks + Transcript parsing | `SubagentStart`/`SubagentStop` hooks + post-run JSONL parse | Agent timing, model, token usage, tool counts |

**Files:**

| File | Purpose |
|------|---------|
| `hooks/telemetry-agent-start.sh` | SubagentStart hook — log agent start event |
| `hooks/telemetry-agent-stop.sh` | SubagentStop hook — log agent stop event + transcript path |
| `hooks/telemetry-merge.sh` | Post-run merge — pair events, parse transcripts, produce unified JSONL record |

**Data layout** (in `$N1_HOME/memory/<ID>/telemetry/`):
- `locks/<run_id>.json` — run identity: host, session ID, transcript path, run ID, version, and ticket ID
- `telemetry.lock` — compatibility pointer to the latest run; never authoritative for cross-session routing
- `raw/steps/<run_id>.jsonl` — orchestrator step events
- `raw/agents/<run_id>.jsonl` — hook agent events
- `runs/<run_id>.jsonl` — merged unified record (query target)

**Event enrichment:** Every JSONL event (steps and agents) contains `n1_version` and `ticket_id`. This ensures even interrupted runs (where the merge script never executes) produce groupable, version-tagged data.

**Lock discovery:** Hooks match the payload session ID and explicit manifest host to a run lock. Missing identity never selects another session's latest run. `n1_run_begin` captures the opening envelope; merging uses that host even when invoked later by another harness. Session-start facts live under `~/.n1/sessions/<session_id>.json`; shared `host.json` is only plugin discovery.

**ID reconciliation:** Telemetry directories live inside `$N1_HOME/memory/<ID>/`, so the existing Reconcile Memory ID & Branch procedure moves them automatically when a provisional ID is replaced with a tracker ticket ID.

Claude hooks filter N1 persona names. Codex hooks validate persona names in the script. Completion merges synchronously; both `Stop` handlers and explicit pipeline finalization use the same merger. Python 3 is required; failure retains the run lock for retry.

**Schema version:** Version **5** corrects v4 accounting. Codex 0.154 `token_usage_record.payload.usage` is per-request; prefer the final cumulative `thread_token_usage`. Request-only fallback requires stable response IDs for deduplication. Legacy cumulative records and `event_msg.token_count.info.total_token_usage` remain supported. Cache-write and reasoning-output fields are preserved; reasoning is already part of output.

Tree totals include the parent and each explicit descendant once. Codex follows read-only `state_5.sqlite` `thread_spawn_edges`, never proximity or working-directory guesses. `root_usage`, `usage_scope`, and `usage_coverage` distinguish a root-only capture from known tree coverage. Unavailable discovery, missing child logs, and unknown independent headless descendants remain explicit. Claude totals include parent plus recorded agent transcripts; duplicate message IDs are counted once. Complete means the indicated coverage has all required fields, not that unregistered headless work was discovered.

Summary input includes fresh input, cache reads, and cache writes on both hosts. `total_tokens` is input plus output. Claude `total_uncached_input_tokens` retains the fresh-input subtotal; agent and orchestrator detail retain native Claude fields. Missing components make the corresponding total `null`, never zero. `total_duration_s` is envelope elapsed time; `total_step_duration_s` is summed step duration and may differ because steps overlap or waits occur outside them. Session usage covers the session lifetime, not only the pipeline envelope interval.

Historical v4 values may have been mislabeled or request-only; do not use them as equivalent benchmarks. Backfill requires an exact verified rollout path, labels reconstruction, and preserves incomplete status. No historical data is rewritten automatically.

**Orchestrator telemetry** (schema v2+):

The merged record includes an `orchestrator` field with per-step tool call and token data for the orchestrator (main Claude Code session), excluding `Agent` tool calls (tracked separately as subagents).

| Field | Type | Description |
|-------|------|-------------|
| `orchestrator.steps[]` | array | Per-pipeline-step tool histogram and token totals |
| `orchestrator.steps[].step` | string | Pipeline step name |
| `orchestrator.steps[].input_tokens` | int | Input tokens consumed during this step |
| `orchestrator.steps[].output_tokens` | int | Output tokens generated during this step |
| `orchestrator.steps[].cache_read_tokens` | int | Cache read tokens during this step |
| `orchestrator.steps[].cache_creation_tokens` | int | Cache creation tokens during this step |
| `orchestrator.steps[].api_calls` | int | Number of API calls during this step |
| `orchestrator.steps[].tool_calls` | int | Number of tool calls (excluding Agent) during this step |
| `orchestrator.steps[].tools_used` | object | Tool name → call count histogram |
| `orchestrator.unattributed` | object | Same shape as a step entry, for API calls outside any step window |
| `orchestrator.totals` | object | Rollup across all steps + unattributed |
| `orchestrator.parse_error` | string\|null | Error string if transcript could not be parsed |

Summary additions: `orchestrator_input_tokens`, `orchestrator_output_tokens`, `orchestrator_tool_calls`, `total_cache_creation_tokens`.

**Session transcript discovery:** The opening envelope captures the path from session-start facts. Completion can supply it without agent events; agent events provide a legacy fallback. Codex can resolve an exact captured thread ID through its read-only state database. Missing paths produce unknown usage.

**Lifecycle support:** [Official Codex hook documentation](https://developers.openai.com/codex/hooks/) documents `Stop` completion and JSON output. The adapter returns `{}` on success. Local validation targets CLI 0.154.0. Manifest registration/trust is NP-145's scope: a declared hook does not prove the plugin registry delivers it. Explicit `n1-start` finalization is available even when hook delivery is absent; interrupted sessions with no delivered completion remain pending rather than claiming completion.

Recovery never guesses that a different concurrent session has become stale. Resume with the captured run identity, or explicitly run `bash hooks/telemetry-merge.sh <run_id> <telemetry_dir>` against the intended interrupted run. Multiple unfinished runs in one session require `N1_RUN_ID`; hooks with only an ambiguous session identity leave them pending.

**Orchestrator transcript fallback:** When no agent event carries `session_transcript_path` (runs before the field was introduced), the merge script derives the parent transcript path from any subagent transcript path that contains `/subagents/`. It strips the subagent suffix to recover the session directory and checks for `<session-dir>.jsonl`. This fallback runs only when primary resolution fails.

**Agent parse_error values:** `transcript_not_found` — agent completed but its transcript file is missing; `transcript_parse_failed` — file exists but jq could not parse it; `agent_never_finished` — no stop event was recorded (agent crashed or run was abandoned).

## Decision events (schema v2.1)

`lib/telemetry.sh:n1_record_decision <id> <result> [<condition_json>] [k=v...]` appends `{"event":"decision","id":...,"result":true|false,"condition":{...},"signals":{"<file.key>":"<value>",...}}` to `raw/steps/<run_id>.jsonl`. Emitted automatically for every `escalation_triggers` / `downgrade_triggers` evaluation in `n1_resolve_model` (id `escalation:<agent>:<step>` or `downgrade:<agent>:<step>`), and explicitly by step files for `simplicity-gate`, `planning-need-direct`, `lite-analysis-gate`, and `simple-path`. The merge collects them into `decisions[]`.

The outcome event gained `review_blocking_count` (Critical/High fingerprints from the first review pass), `review_fix_cycles`, `qa_fix_cycles`, `break_check_verdict`, `review_discarded_count`. `n1-telemetry` correlates `decisions[].id`/`result` with these fields and refuses threshold recommendations below `telemetry.minPairedRuns` (default 100).

## Question events (schema v2.2)

`lib/telemetry.sh:n1_emit_question_event` appends `{"event":"question","step":"...","question_category":"design|mechanical|quality|scope","resolution":"asked|auto|auto-decided|decide-for-me|inherited","rungs_tried":"codebase,web,..."}` to `raw/steps/<run_id>.jsonl`. Emitted by analysis (Phase 3), brainstorm (A-tier questions), fix (escalation), and investigation-deliverable (Phase 2) steps. The merge collects them into `questions[]`.

`n1-telemetry` reports questions/run by step, resolution distribution, and an earned-autonomy trend line. `scripts/benchmark.py` includes `QuestionMetric` and `QuestionShareMetric` for cross-version comparison.
