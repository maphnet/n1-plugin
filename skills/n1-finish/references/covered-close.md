# Covered Close (N1-528)

Read from Step 4 only after this run's delivery gate recorded `- **Delivery:** succeeded (`. That happens only in the interactive Execute branch, after the user confirmed the deploy. `<ID>` is this ticket, `<SHA>` is the delivered merge SHA (03b's `<SHA>`), and `<verified | not verified>` is this run's verify result. The delivery of `<SHA>` shipped the whole tree at `<SHA>`, so every earlier merge that is an ancestor of it is deployed too. This procedure closes those other deploy-pending tickets. It never changes this ticket's own close.

## 1. Scan

```bash
source ~/.n1/preamble.sh
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
X="<SHA>"; case "$X" in ""|*[!0-9a-f]*) echo sha:invalid; exit 1;; esac
echo "fullauto:$(n1_fullauto_enabled)"
n1_delivery_covered "$X" "$ID"
```

Each `<C> <merge-sha> ok` line is a covered ticket. Each `<C> <merge-sha> actions` line is excluded: its runbook still has unticked Deployment Actions, so it is reported and never closed here (resume it with `/n1:n1-finish <C>`). No `ok` and no `actions` line → print nothing, and record `Covered: none` for the Step 6 Report. Return to Step 4.

## 2. Decide (once for the whole batch)

- `fullauto:true` and the `- **Delivery:** succeeded (` value just recorded for <ID> has no `skipped steps:` part, or says `skipped steps: none` → close every `ok` ticket whose key prefix `${C%-*}` equals `${ID%-*}` without a prompt; any other-project ticket goes to the prompt below. Print the list first: "Delivery of <SHA> also covers: <C> (<merge-sha>), ...".
- Otherwise ask the user once (a delivery that skipped steps never auto-closes: the covered tickets' own steps may not have run, so add the line `The delivery skipped steps <numbers>.` to the prompt). If `N1_HEADLESS=1` is set anyway, take option 2 and do not ask.
  ```
  Delivery of <SHA> (<ID>) also shipped these deploy-pending tickets:
    <C> — merge <merge-sha>
    ...
  Not closed (unticked Deployment Actions): <C>, ... | none
  No recommendation. The options are equivalent given the available evidence; select based on team preference.
  1 — Close all listed tickets (Delivery succeeded, ticket moved to <tracker.statuses.done>)
  2 — Leave them pending
  ```
  Option 2 → change nothing, record `left pending (declined) <IDs>` for the Report, and return to Step 4.

## 3. Local record (per approved ticket, before any tracker call)

Run this once per `ok` ticket `<C>`. The record is written before the tracker call, and `deploy_pending` is cleared only after the Delivery line was written.

```bash
source ~/.n1/preamble.sh
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
X="<SHA>"; case "$X" in ""|*[!0-9a-f]*) echo sha:invalid; exit 1;; esac
C="<C>"; case "$C" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
OV="$N1_HOME/memory/$C/overview.md"
if n1_finish_line_set "$OV" Delivery "succeeded (covered by $ID at $X)" \
   && n1_write_frontmatter "$OV" deploy_pending false; then
  [ -z "$(n1_read_frontmatter "$OV" deploy_next_step)" ] || n1_write_frontmatter "$OV" deploy_next_step 0 || true
  n1_pending_clear "$OV" || true
  echo "record:ok $C"
else
  echo "record:failed $C"
fi
```

`record:failed` → warn "Could not update memory for <C>; it stays deploy-pending.", skip its tracker close, record it as `left pending (record failed)`, and continue with the next ticket.

## 4. Tracker close (per recorded ticket)

`tracker.mcp` null → the Ticket value is `tracker not configured`; go to step 5. `tracker.statuses.done` absent → the Ticket value is `left open (no done status configured)`; go to step 5.

Otherwise use the Step 4 close mechanics (Call batching, Move status, idempotency) with `<C>` in place of `<ID>`. Batch all recorded tickets: Turn 1 issues every read (`getTransitions`, `getComments` when configured) in parallel, and Turn 2 issues every status move and comment in parallel.
- Move: Jira `mcp__<tracker.mcp>__<operations.getTransitions>` → the transition whose target equals `tracker.statuses.done` → `mcp__<tracker.mcp>__<operations.moveStatus>`; YouTrack `mcp__<tracker.mcp>__<operations.moveStatus>` with the `done` state. Already in `done` → skip the move.
- Comment via `mcp__<tracker.mcp>__<operations.addComment>`. Verified: `Covered by <ID>: merge <merge-sha> is included in the delivery of <SHA>. Deployment verified via <ID>.` Not verified: `Covered by <ID>: merge <merge-sha> is included in the delivery of <SHA>. Deployed via <ID> (not verified).` Skip it when an identical comment is already present (idempotent re-run).
- Tracker failures: warn, never block. The local record stays. The Ticket value is `left open (tracker close failed)`.

## 5. Ticket line (per recorded ticket)

```bash
source ~/.n1/preamble.sh
C="<C>"; case "$C" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
n1_finish_line_set "$N1_HOME/memory/$C/overview.md" Ticket "<moved to <done status> | left open (no done status configured) | left open (tracker close failed) | tracker not configured>" || echo "ticket-line:failed $C"
```

Use only the literal values above (no quotes, `$` or backticks in the value).

## 6. Return

Never run a deploy, Step 5 or Step 6 for a covered ticket. Their worktrees are left to `/n1:n1-clean`. Keep the result for this ticket's Step 6 Report as `Covered: closed <IDs>; excluded (unticked actions) <IDs>; left pending (<declined | record failed>) <IDs>`, including only the non-empty parts. Return to Step 4, which continues with Step 5.
