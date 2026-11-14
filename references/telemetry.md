### Telemetry

Always-on local-first telemetry (no config key). Captures per-step timing, per-agent performance, and token consumption for offline efficiency analysis.

**Two-layer collection:**

| Layer | Source | Captures |
|-------|--------|----------|
| Orchestrator markers | `date -u` calls at step boundaries in `n1-start` | Step name, timing, outcome, loop counts |
| Hooks + Transcript parsing | `SubagentStart`/`SubagentStop` hooks + post-run JSONL parse | Agent timing, model, token usage, tool counts |

**Files:**

| File | Purpose |
|------|---------|
| `hooks/telemetry-agent-start.sh` | SubagentStart hook — log agent start event |
| `hooks/telemetry-agent-stop.sh` | SubagentStop hook (synchronous, so its warning is delivered) — log agent stop event + transcript path; when the persona left `bash -c` shells running in the run's worktree, warns via a `systemMessage` and adds `leftover_shells` (`[{pid, age_s}]`, each shell reported once, never killed) to the raw stop line only, not merged (N1-317) |
| `hooks/telemetry-merge.sh` | Post-run merge — pair events, parse transcripts, produce unified JSONL record |

**Data layout** (in `$N1_HOME/memory/<ID>/telemetry/`):
- `locks/<run_id>.json` — run identity: host, session ID, transcript path, run ID, version, and ticket ID
- `telemetry.lock` — compatibility pointer to the latest run; never authoritative for cross-session routing
- `raw/steps/<run_id>.jsonl` — orchestrator step events
- `raw/agents/<run_id>.jsonl` — hook agent events
- `runs/<run_id>.jsonl` — merged unified record (query target)

**Event enrichment:** Every JSONL event (steps and agents) contains `n1_version` and `ticket_id`. This ensures even interrupted runs (where the merge script never executes) produce groupable, version-tagged data.

**Lock discovery:** Hooks match the payload session ID and explicit manifest host to a run lock. Missing identity never selects another session's latest run. `n1_run_begin` captures the opening envelope; merging uses that host even when invoked later by another harness. Session-start facts live under `~/.n1/sessions/<session_id>.json`; shared `host.json` is only plugin discovery. In-snippet writers restore `N1_RUN_ID` from the session's active-run pointer and check it against the ticket being written before emitting; the rules live once in `n1_bind_run_to_ticket` (lib/telemetry.sh).

**ID reconciliation:** Telemetry directories live inside `$N1_HOME/memory/<ID>/`, so the existing Reconcile Memory ID & Branch procedure moves them automatically when a provisional ID is replaced with a tracker ticket ID.

Hooks filter N1 persona names. Explicit finalization or error recovery writes the terminal envelope and merges synchronously. Finalization keeps the run lock, so the turn's `Stop` re-merges the calls made after it (Gate 3, chained `n1-finish`) and then removes the lock; calls made after that `Stop` (a later turn, or a standalone `/n1:n1-finish` in the same or another session) are not covered. If the `Stop` cannot clean up (a background agent still pending, or a continuation block), the lock stays until a later `Stop` removes it. A `Stop` records its transcript, then retains only the selected run when this session's active-run pointer names that exact run and no terminal envelope exists. Cleanup still merges a run with no active pointer (or an already-terminal run). Python 3 is required; failure retains the run lock for retry.

**Schema version:** Version **6** derives compactions from `compact_boundary` records in the orchestrator (main session) transcript and adds per-step orchestrator context size. In v<=5, `compaction_count` came from a SessionStart(compact) hook gated by the run lock. That hook missed post-run compactions and counted subagent auto-compactions, so it is an undercount and not comparable with v6. Version **5** corrects v4 accounting. Legacy cumulative records and `event_msg.token_count.info.total_token_usage` remain supported. Cache-write and reasoning-output fields are preserved; reasoning is already part of output. Pre-4.0 records with `host: codex` are read as-is with no special handling — the schema no longer distinguishes hosts.

Tree totals include the parent and each explicit descendant once. `root_usage`, `usage_scope`, and `usage_coverage` distinguish a root-only capture from known tree coverage. Unavailable discovery, missing child logs, and unknown independent headless descendants remain explicit. Claude totals include parent plus recorded agent transcripts; duplicate message IDs are counted once. Complete means the indicated coverage has all required fields, not that unregistered headless work was discovered.

Summary input includes fresh input, cache reads, and cache writes. `total_tokens` is input plus output. Claude `total_uncached_input_tokens` retains the fresh-input subtotal; agent and orchestrator detail retain native Claude fields. Missing components make the corresponding total `null`, never zero. `total_duration_s` is envelope elapsed time; `total_step_duration_s` is summed step duration and may differ because steps overlap or waits occur outside them. Session usage covers the session lifetime, not only the pipeline envelope interval.

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
| `orchestrator.steps[].context_start_tokens` | int\|null | Orchestrator context (input + cache_read + cache_creation) of the last main-thread message before the step's first message; the step's first message when none precedes it (v6) |
| `orchestrator.steps[].context_end_tokens` | int\|null | Context of the step's last main-thread message (v6) |
| `orchestrator.steps[].context_peak_tokens` | int\|null | Largest main-thread context within the step (v6) |
| `orchestrator.steps[].compactions` | int | Compaction boundaries inside the step window. When > 0, end minus start is not growth. Steps without assistant messages have no `steps[]` entry, so `orchestrator.compactions[]` / `summary.compaction_count` is the authoritative count (v6) |
| `orchestrator.compactions[]` | array | Main-transcript `compact_boundary` records with `started_at <= timestamp <= completed_at` (no upper bound when `completed_at` is missing; compared at 1-second resolution, timestamps truncated to `YYYY-MM-DDTHH:MM:SS`): `{timestamp, trigger: auto\|manual\|unknown, pre_tokens, post_tokens}` (v6) |
| `orchestrator.unattributed` | object | Same shape as a step entry, for API calls outside any step window, after the N1-556 lead-in and trailing attribution below (startup calls before the first step end and before `run_start`). Figures merged before 5.96.9 are not comparable |
| `orchestrator.tail` | object | Same shape as `unattributed`, for API calls after envelope `completed_at` (FINALIZE, Gate 3, chained `n1-finish`). A subset already counted in `totals`, usually inside the `finish` step (not guaranteed when the run never reached finish, or when a later step such as `release` begins first); never add it to them. Absent when the transcript is unparsed (N1-229) |
| `orchestrator.model` | string\|null | Most frequent main-thread `message.model`, `<synthetic>` excluded |
| `orchestrator.context_window` | int\|null | Assumed window from a model-id prefix lookup (`claude-opus-5`, `claude-sonnet-5` -> 1,000,000), not a measurement: the model id does not reveal a smaller window. `null` for any other model |
| `orchestrator.context_window_source` | string\|null | `model_prefix_lookup` when `context_window` is set, else `null` |
| `orchestrator.transcript_path` | string | Orchestrator transcript the merge parsed |
| `orchestrator.totals` | object | Rollup across all steps + unattributed |
| `orchestrator.parse_error` | string\|null | Error string if transcript could not be parsed |

Context fields and compaction boundaries skip `isSidechain` records. Token sums still include them.

**Step windows (N1-229):** A step missing its begin or end is filled from its chronological neighbour (previous step's end / next step's begin) or the envelope bound and flagged `window_inferred: true`; real timestamps are never overwritten, except the `finish` end below. The `finish` step's end is extended to the last transcript message, or to the start of the next step if one begins first (`window_extended: true`, recorded `completed_at` replaced) because `finish.md` begins and ends it back to back before FINALIZE and the chained `n1-finish`. Startup calls before the first step window stay in `unattributed`. A step that re-begins and ends again after its first end (review-fix cycles 2+ reuse `review` and `fix`) keeps each later start/end pair as an extra window with `loop_iteration` 2, 3, and so on; the analyzer reports them as one summed `<step> (cycle 2+)` row. Token and tool figures for those windows stay in the base step entry.

**Lead-in and trailing attribution (N1-556, 5.96.9):** `n1_step_begin` emits `started_at` after the model message that issues it, so a call in no step window is attributed to the step that begins next (lead-in) once a step has ended or the call is at or after `run_start`; a call after the last step's end is attributed to that last step (trailing). Step `started_at`, `completed_at` and `duration_s` are not changed. An `orchestrator.steps[]` entry that received such calls carries `attribution_extended: true`; `compactions` use the lead-in attribution only, so a compaction in a step gap counts in the step it leads into; a compaction after the last step's end is not counted in any step (it stays in `orchestrator.compactions[]`). A trailing call after the run end (`completed_at` of the run) stays unattributed. Records merged before 5.96.9 attribute these calls to `unattributed`, so per-step tokens and the unattributed share are not comparable across that version; re-merge (`hooks/telemetry-merge.sh <run_id> <telemetry_dir>`) to compare.

Summary additions: `orchestrator_input_tokens`, `orchestrator_output_tokens`, `orchestrator_tool_calls`, `total_cache_creation_tokens`. v6: `compaction_count`, `compaction_auto_count`, `compaction_manual_count`, and `compaction_timestamps` come from `orchestrator.compactions[]`. All four are `null` when the orchestrator transcript was not parsed. A boundary with an `unknown` trigger counts toward the total only.

**Session transcript discovery:** The opening envelope captures the path from session-start facts. Completion can supply it without agent events; agent events provide a legacy fallback. Missing paths produce unknown usage.

**Lifecycle support:** `Stop` is a turn hook, not session completion: it records parent transcript data but does not close a matching active run. Explicit `n1-start` finalization or error recovery provides the terminal envelope and completion. SessionStart (`startup`, `resume`, `clear`) is the recovery path for runs whose session ended without finalization (N1-486): `n1_merge_pending` scans every run lock in the project and closes a run with `final_outcome: abandoned` (envelope, merge, lock removal) only when the lock is not the current session's, its `active-run.<session>.json` pointer has no live claude `pid`, and the run has been idle for more than 24 hours (mtime of `raw/steps/<run>.jsonl`, lock mtime as fallback). A missing pointer or a pointer without `pid` gives no liveness signal, so the idle rule alone decides. An agent start without a matching stop does not block this path. At most 20 runs are abandoned per start, so the first starts after upgrading drain old locks as a one-time burst of `abandoned` runs. A handoff that cleared the pointer while work continues elsewhere also ends as abandoned; the continuation has its own run id. A headless run paused for more than 24 hours whose recorded pid is not a claude process reads as dead and is abandoned. There is no `SessionEnd` handler. Manifest registration/trust is NP-145's scope: a declared hook does not prove the plugin registry delivers it.

Recovery never touches a run whose owner pid is a live claude process, whatever its age. Resume with the captured run identity, or explicitly run `bash hooks/telemetry-merge.sh <run_id> <telemetry_dir>` against the intended interrupted run. Multiple unfinished runs in one session require `N1_RUN_ID`; hooks with only an ambiguous session identity leave them pending.

**Orchestrator transcript fallback:** When no agent event carries `session_transcript_path` (runs before the field was introduced), the merge script derives the parent transcript path from any subagent transcript path that contains `/subagents/`. It strips the subagent suffix to recover the session directory and checks for `<session-dir>.jsonl`. This fallback runs only when primary resolution fails.

**Agent parse_error values:** `transcript_not_found` — agent completed but its transcript file is missing; `transcript_parse_failed` — file exists but jq could not parse it; `agent_never_finished` — no stop event was recorded (agent crashed or run was abandoned).

## Decision events (schema v2.1)

`lib/telemetry.sh:n1_record_decision <id> <result> [<condition_json>] [k=v...]` appends `{"event":"decision","id":...,"result":true|false,"condition":{...},"signals":{"<file.key>":"<value>",...}}` to `raw/steps/<run_id>.jsonl`. The merge collects them into `decisions[]`.

Emitted decision ids (N1-596). This is the same set as `KNOWN_GATE_IDS` and `GATE_ID_PREFIXES` in `scripts/benchmark.py`:

- `escalation:<agent>:<step>` and `downgrade:<agent>:<step>`: emitted automatically for every `escalation_triggers` / `downgrade_triggers` evaluation in `n1_resolve_model` (`lib/config.sh`).
- `lite-analysis-gate` and `simple-path` (`lib/analysis.sh`), `qa-engineer-skip` (`lib/qa-step.sh`), `codex-review` (`lib/codex-review.sh`).
- `simplicity-gate` (`skills/n1-start/steps/implementation.md`), `release-gate` (`skills/n1-start/steps/release.md`), `local-testing-gate`, `local-testing-offer` and `local-testing-auto-skip` (`skills/n1-start/steps/local-testing.md`), `review-tier` (`skills/n1-start/review-core.md`).

Raw telemetry also contains ids that the orchestrator improvised and that have no emit site: `review-rerun`, `finish-merge`, `review-fix-cap`, `review-extra-cycle` and `review-fix-cap-extra`. The merge keeps them. The benchmark gate counts (`## Gate Activation Rates`) and the `n1-telemetry` gate table ignore every id that is not in the list above. To add a gate, add the emit site, the registry entry in `scripts/benchmark.py` and a line here. `GateRegistryTest` in `tests/test_benchmark.py` fails when these three disagree.

The outcome event gained `review_blocking_count` (blocking Index lines of the first review pass: Critical/High, any `[RULE-N]`, an in-diff non-Low `[SEC-N]`; from 5.83.0 read from the overview key `review_c0_blocking` written at cycle-0 review collect, before that and when the key is missing it counts Critical/High fingerprints only, so per-version means mix both definitions around 5.83.0), `review_pass_first_try_hard` (5.83.0+, N1-483: `true` when that cycle-0 count is 0, `false` otherwise, empty when no cycle-0 count was recorded; `review_pass_first_try` keeps meaning `review_fix_cycle == 0`), `review_fix_cycles`, `qa_fix_cycles`, `break_check_verdict` (`skipped` for a non-bug ticket in mode `bugs` without a `Regression test:` line, and when no verdict was recorded), `review_discarded_count`, `review_unresolved_at_pr` (N1-211: `true` when the fix cap left findings open). `n1-telemetry` correlates `decisions[].id`/`result` with these fields and refuses threshold recommendations below `telemetry.minPairedRuns` (default 100). `qa_fix_cycles` counts real QA fixes only; runs before 5.3.3 incremented it on every run, so older values are inflated by 1. The summary `review_fix_cycles`/`qa_fix_cycles` come from the outcome event (max across events) and are `null` when no outcome was emitted; `review_blocking_count` and `break_check_verdict` take the first outcome event. The analyzer reports per-run `fix_cycles_hard/soft/codex` derived from `implementation.md` headings (null when the file is missing) and aggregates them per project slug in `by_project` next to the raw `fix_cycles` total (N1-213). The analyzer `collect --last` defaults to 20 only when no `--since`/`--until` window is given.

## Question events (schema v2.2)

`lib/telemetry.sh:n1_emit_question_event` appends `{"event":"question","step":"...","question_category":"design|mechanical|quality|scope","resolution":"asked|auto|auto-decided|decide-for-me|inherited","rungs_tried":"codebase,web,..."}` to `raw/steps/<run_id>.jsonl`. Emitted by analysis (Phase 3), brainstorm (A-tier questions), fix (escalation), and investigation-deliverable (Phase 2) steps. The merge collects them into `questions[]`.

`n1-telemetry` reports questions/run by step, resolution distribution, and an earned-autonomy trend line. `scripts/benchmark.py` includes `QuestionMetric` and `QuestionShareMetric` for cross-version comparison.

## Stuck events

`hooks/stuck-detector.sh` (N1-342) appends `{"event":"stuck","kind":"nudge|stop","run_id","ticket_id","session_id","agent_id","tool":"Bash","count":N,"hash":"<12 hex>","timestamp"}` to `raw/steps/<run_id>.jsonl` when the hook's session owns a run lock (`n1_read_lock`); otherwise nothing is written. `nudge` is emitted once per streak at the 3rd identical failure, `stop` once per streak at the first denied call after 5. `agent_id` is `main` for the orchestrator. The merge ignores these lines (no `layer`, no collected `event` name); they are read from the raw file until an analyzer needs a merged `stuck_events[]` field.
