# Step 4: After-Deploy Actions (deferred or unticked rows)

Read from `steps/04-close-ticket.md` § After-deploy actions only when § Parse printed `deferred:<M>` or `unticked:<N>` above 0; it is not read at entry. `<N1_ROOT>/references/deployment-actions.md` was already read at entry; do not re-read it. "Continue below" means: return to `04-close-ticket.md` right after its After-deploy actions block (the Hard-skip gate).

1. When § Parse printed `deferred:<M>` with M > 0, keep the items from its `deferred #<n> <item>` lines for the Step 6 Report's `Deferred to release:` line (a mid-step message is lost in hand-off mode); n1-finish never walks, ticks or writes them to the runbook. No line when `deferred:0`. Then: `unticked:0` → continue below.
2. **Deploy confirmed.** This means the Step 3 deploy status is `succeeded`, delivery is `succeeded`, or this run resumed a pending deploy in Step 1:
   - `mode:runbook` → run § Check only when the Step 3 deploy status is `succeeded` or delivery is `succeeded` (a Step 1 resume alone does not count: no deploy was watched in this run, so run no check). When it applies, first, for each row with phase `after` that § Command classifies `check`, run § Check (no prompt; a failed or inconclusive check leaves the row). Then § Runbook with `ID=<ID>` and `SHA=<SHA>`. `runbook:none` (every unticked row was a passing check) → go to item 4 and close the ticket as usual. Any other output → do not close the ticket: when delivery is `succeeded`, run the covered-tickets paragraph at the end of `04-close-ticket.md` first; skip the rest of Step 4 and Step 5, and go to Step 6.
   - `mode:walk` → § Walk with `PHASE=before` and `LATE=1` for any still-unticked `before` rows (the PR merged without them, so the deploy already ran; each is labeled and offered, never run silently), then § Walk with `PHASE=after` (its `check` rows run without a prompt). The PR is already merged: an aborted `PHASE=before` walk (including "No" to "Continue anyway?") only stops offering before-deploy items — it does not skip the `PHASE=after` walk that follows.
3. **Deploy not watched** (`none triggered` or `skipped (no deploy workflow…)`): `mode:runbook` → leave the rows unticked for n1-release or a later run (no check runs without a watched deploy), and continue below. `mode:walk` → § Unwatched Deploy.
4. After any walk, complete or aborted, or after `runbook:none`, clear the pending flag and continue below. After-deploy actions never block the ticket close; unticked rows stay in the PR body. Keep each item's outcome (ticked with its evidence, skipped, failed, or left in the runbook) for the Step 6 Report's `Deployment actions:` line; a mid-step message is lost in hand-off mode.
   ```bash
   source ~/.n1/preamble.sh
   case "<ID>" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   ```
