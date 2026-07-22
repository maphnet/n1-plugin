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
- `telemetry.lock` — JSON lock: `{"run_id":"...","n1_version":"..."}` (ticket_id derived from parent directory name)
- `raw/steps/<run_id>.jsonl` — orchestrator step events
- `raw/agents/<run_id>.jsonl` — hook agent events
- `runs/<run_id>.jsonl` — merged unified record (query target)

**Event enrichment:** Every JSONL event (steps and agents) contains `n1_version` and `ticket_id`. This ensures even interrupted runs (where the merge script never executes) produce groupable, version-tagged data.

**Lock discovery:** Hooks resolve `N1_HOME` via the standard preamble and glob for `${N1_HOME}/memory/*/telemetry/telemetry.lock`, taking the most recent by mtime when multiple exist. No lock = silent exit (zero overhead for non-telemetry runs).

**ID reconciliation:** Telemetry directories live inside `$N1_HOME/memory/<ID>/`, so the existing Reconcile Memory ID & Worktree procedure moves them automatically when a provisional ID is replaced with a tracker ticket ID.

Hooks use `matcher: "n1:*"` — zero overhead for non-N1 sessions. All collection is async and non-blocking.
