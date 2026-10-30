# Step 2: Merge State Machine

N1 merges an open PR only when the entry printed `merge-on-finish:yes` (`finishWork.mergeOnFinish` is `true`; a queue or headless run also needs `autonomy.fullAuto` `true`). Otherwise the human merges, then re-runs n1-finish.

With `headless:yes` or `queue-run:yes`, every **STOP** in 3.1 and 3.4 (and in resolve-dirty.md), except the 3.4 merge-queue outcome (`merge-exit:0` with `state:OPEN`), is also added under `## Escalations` and posted as a `N1 [headless]` tracker comment.

**Queue runs.** When the entry printed `queue-run:yes` without `merge-on-finish:yes`, report "Queue run: N1 merges only when `autonomy.fullAuto` and `finishWork.mergeOnFinish` are both true. The ticket stops after PR + CI." **STOP.** This covers both the PR path and Step 2b.

The Step 1 marker (`n1_finish_mark`) already gates this step and Step 2b; every **STOP** here clears it (`n1_active_run_clear_if n1-finish`).

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP.**
3. **`OPEN`:**
   1. **Pre-merge checks** (only with `merge-on-finish:yes`; otherwise skip to 3.2): read `<N1_ROOT>/skills/n1-finish/references/merge-on-finish.md` now (it is not read at entry) and run its § 3.1. N1 never merges an open PR without it.
   2. **Deployment actions:** follow `<N1_ROOT>/references/deployment-actions.md` § Parse (already read at entry; do not re-read) with `PRS=<n>` and `OUT=$N1_HOME/scratch/deploy-actions-<n>.tsv`.
      - `fetch-failed:#<n>` → "Could not read the PR #<n> body, so its deployment actions are unknown. Re-run `/n1:n1-finish`." **STOP.**
      - `unticked:0` → nothing to do.
      - `mode:runbook` (headless run) with any unticked row → § Runbook with `ID=<ID>` and an empty `SHA`. Report "Deployment actions pending for <ID>. Resume with `n1-finish <ID>` (runbook in N1 memory)." **STOP.**
      - `mode:walk` with `before` rows → § Walk with `PHASE=before`. `WALK=aborted` → "Merge blocked: before-deploy actions are not complete. Re-run `/n1:n1-finish` when ready; ticked actions are not repeated." **STOP.**
      - `after` rows wait for Step 4.
   3. **Without `merge-on-finish:yes`:** report "PR #<n> is open. Merge it, then re-run /n1:n1-finish." **STOP.**
   4. **With `merge-on-finish:yes`:** run § 3.4 of `merge-on-finish.md` (read in 3.1; do not re-read).

## Step 2b: Local Merge (no-PR path, `prMode == "skip"` only)

**Chained runs:** when the entry printed `chained:yes` without `merge-on-finish:yes`, report "Branch <b> is not merged. Run /n1:n1-finish <ID> to merge locally." **STOP.** Otherwise read `<N1_ROOT>/skills/n1-finish/references/local-merge.md` now (it is not read at entry) and follow it; never merge locally without it.

## Hand-off

With `handoff:yes`, every "Go to Step 3" or "Go to Step 4" above (the merge happened or was already done) runs `steps/handoff.md` instead of Steps 3-6; a **STOP** never hands off.
