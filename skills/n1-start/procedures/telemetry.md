# Procedure: Telemetry

Covers telemetry initialization at run start and step-marker emission throughout the pipeline.

## Telemetry Initialization

Read `telemetry.enabled` from `$N1_HOME/config.json` (default `false` if absent or if `telemetry` block is missing).

**If `telemetry.enabled` is `true`:**
1. Read plugin version:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   N1_VERSION=$(n1_plugin_version)
   ```
2. Generate run ID:
   ```bash
   N1_RUN_ID=$(date -u +n1-run-%Y%m%dT%H%M%SZ)
   ```
3. Create per-ticket telemetry directories:
   ```bash
   mkdir -p "${N1_HOME}/memory/$ID/telemetry/raw/steps" "${N1_HOME}/memory/$ID/telemetry/raw/agents" "${N1_HOME}/memory/$ID/telemetry/runs"
   ```
4. Write JSON lock file:
   ```bash
   echo '{"run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'"}' > "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
   ```
5. Write active-run pointer (regardless of telemetry setting):
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
   ```
   This file is read by the session-start hook on compaction to restore orchestrator state. It is NOT gated on `telemetry.enabled`.

Where `$ID` is the ticket ID or provisional slug — the same `<ID>` used for the memory directory. The telemetry directory is created at the same moment as the memory directory (using provisional ID if the final ID is not yet known). Since telemetry lives inside `$N1_HOME/memory/<ID>/`, the existing **Reconcile Memory ID & Branch** procedure moves it automatically when the ID changes.

**If `telemetry.enabled` is `false`:** Skip all telemetry shell calls throughout the pipeline. Do not generate `N1_RUN_ID`, do not write lock files, do not emit step markers. The hooks will also exit silently (no lock file = no-op).

Throughout the pipeline, `N1_RUN_ID` and `N1_VERSION` are passed to each telemetry shell call explicitly — do not rely on them persisting between shell calls.

## Telemetry Step Markers

**If telemetry is enabled**, emit a step marker at the start and end of each pipeline step using the shared helper:

**Step start:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Step end:**
```bash
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=<pass|fail|skip> loop_iteration=<N|null> metadata='<JSON>'
```

**Skipped steps** get a single call with `outcome=skip` (no separate start event needed).

Step numbering and names:

| step_number | step name | metadata fields |
|-------------|-----------|-----------------|
| 1 | `ticket` | `{}` (writes `tier` to overview.md frontmatter) |
| 2 | `analysis` | `{}` (may update `tier` in overview.md frontmatter). When `relatedProjects.enabled` is `true`, `steps/analysis.md` owns the end event and adds `cross_repo_explored`, `cross_repo_projects`, `cross_repo_maps_generated`, `cross_repo_discovery_new` — do not emit a second end event here. |
| 3 | `brainstorm` | `{"planning_need":"plan\|direct"}` |
| 4 | `plan` | `{}` |
| 5 | `plan-review` | `{"verdict":"CLEAN\|FIXED"}` |
| 6 | `estimation` | `{"tier":"XS\|S\|M\|L\|XL"}` |
| 7 | `implementation` | `{"execution_path":"direct|sdd"}` (+ `cross_repo_runtime_detected`, `cross_repo_runtime_added` when `relatedProjects.enabled` — see procedures/cross-repo.md §5b) |
| 8 | `qa` | `{"loop_iteration":<N>}` |
| 9 | `review` | `{"findings_total":<N>,"findings_critical":<N>}` (+ `cross_repo_xrepo_findings` when `relatedProjects.enabled` — see procedures/cross-repo.md §7b) |
| 10 | `fix` | `{"loop_iteration":<N>}` |
| 11 | `local-testing` | `{"action_type":"live\|test_only\|skipped\|smoke_deferred","infra_started":<bool>,"app_started":<bool>,"services":[...],"scenario_types":[...],"qa_overlap_pct":<int\|null>}` |
| 12 | `pr` | `{}` |
| 13 | `ci` | `{}` |
| 14 | `finish` | `{}` |
| 17 | `smoke` | `{"action_type":"smoke_executed","endpoint_status":<string\|null>,"tests_total":<int>,"tests_passed":<int>}` |

**Naming note:** The overview.md frontmatter `tier:` field (values: `simple`/`standard`/`complex`) controls model/effort routing. The brainstorm `planning_need` value (values: `plan`/`direct`) controls pipeline branching — whether a formal plan is needed. The estimation body line `**Complexity:** XS/S/M/L/XL` is delivery sizing. These three concepts are independent.

Each step section in the pipeline should emit its start marker before spawning agents and its end marker after updating overview.md.
