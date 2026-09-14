# Step 4: Close Ticket

**Hard-skip gates** — when either holds, skip immediately with the stated reason and go to Step 5:
- `closeTicket` is `false` → "Ticket close skipped: closeTicket is false."
- `tracker.mcp` is null → "Ticket close skipped: no tracker configured."

**Runtime recovery** — when the hard-skip gates pass but `tracker.statuses.done` is absent from config: read `<N1_ROOT>/skills/n1-finish/references/done-status-recovery.md` for the full detection and prompt procedure.

**When `tracker.statuses.done` was already present in config, or after successful recovery above, proceed:**

1. **Move status** via the operations map:
   - Jira: `mcp__<tracker.mcp>__<operations.getTransitions>` → find the transition whose target status equals `tracker.statuses.done` → `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
   - YouTrack: `mcp__<tracker.mcp>__<operations.moveStatus>` (`update_issue`) with the `done` state value.
   - If the ticket is already in the `done` status → skip the move silently (idempotent re-run).
2. **Add comment** via `mcp__<tracker.mcp>__<operations.addComment>`, one of:
   - `"PR merged: <PR URL>"` (deploy not watched)
   - `"PR merged: <PR URL>. Deployment succeeded: <run URL>"` (deploy watched)
   When `operations.getComments` exists, check recent comments first and skip if an identical comment is already present (idempotent re-run); otherwise add best-effort once.
3. Tracker failures: **warn, never block** — the merge already happened. Record the failure in the report.
