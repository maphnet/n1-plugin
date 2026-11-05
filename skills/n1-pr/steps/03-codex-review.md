<!-- Purpose: Pin the reviewed head, post the pre-push Codex triage once, disclose unreviewed soft fixes, then print the final report. -->

## Step 9: Codex Comment

If no PR URL is available, PR creation failed: end n1-pr without a review report.

The Codex review already ran before the push (step 1, N1-405). This step never runs it again and never pushes. It first pins the PR head that passed N1 review (`$N1_HOME/review-pins/`, any Codex outcome). n1-finish merges only that head, and reconcile § Check advances it after N1's fix-loop pushes. Codex fix commits were recorded as post-review heads in step 1, so they keep the pin valid. `pin:unavailable` is not an error (n1-finish then refuses to merge). `pin:refused` prints its reason (no review artifacts, non-PASS verdict, or `unreviewed-head`: an unrecorded post-review commit or a stale review): let the block finish and report it; never write the pin file by hand.

It then reads the branch receipt and posts the saved triage once. A PostToolUse hook records `outcome=skipped reason=step-not-run` when the PR was created without a pre-push review, and the Stop hook requests continuation until this step has run. Receipts live under `$HOME/.n1/review-receipts/<session>/<repo>__<branch>.json` (with the reviewed head; a `ran` receipt counts only while that head is an ancestor of HEAD), even without telemetry.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
ID='<the ticket ID>'
PR_URL='<the PR URL from step 4>'
n1_review_pin set "${PR_URL##*/}"
BRANCH=$(git branch --show-current)
OUTCOME=$(n1_review_outcome "$BRANCH")
MISSED=""
[ -n "$OUTCOME" ] || { n1_review_record "$BRANCH" skipped step-not-run true; OUTCOME=skipped; MISSED=1; }
echo "codex_review_outcome=$OUTCOME"
if [ -n "$MISSED" ] && ! timeout -k 5 30 gh pr view "$PR_URL" --json comments --jq '.comments[].body' 2>/dev/null | grep -q '^## Codex Review Not Run'; then
  timeout -k 5 30 gh pr comment "$PR_URL" --body '## Codex Review Not Run

The pre-push Codex review did not run for this PR. Treat it as not cross-reviewed.' >/dev/null 2>&1 && echo "omitted:posted" || echo "omitted:comment-failed"
fi
case "$ID" in ''|*[!A-Za-z0-9_-]*) echo "triage:no-id"; exit 0;; esac
TRIAGE_FILE="$N1_HOME/memory/$ID/codex-triage.md"
{ [ -f "$TRIAGE_FILE" ] && [ ! -L "$TRIAGE_FILE" ] && [ "$(stat -c %h "$TRIAGE_FILE")" = 1 ]; } || { echo "triage:none"; exit 0; }
if timeout -k 5 30 gh pr comment "$PR_URL" --body-file "$TRIAGE_FILE" >/dev/null 2>&1; then
  mv -f "$TRIAGE_FILE" "$N1_HOME/memory/$ID/codex-triage.posted.md" && echo "triage:posted"
else echo "triage:comment-failed file=$TRIAGE_FILE"; fi
```

- `triage:posted`: the PR's only Codex comment holds the validated triage.
- `triage:none`: nothing to post (no findings, opt-out, or the review did not run).
- `triage:comment-failed file=<path>`: warn inline with the path and remember the follow-up item `Codex triage not posted: see ticket memory codex-triage.md`.
- `triage:no-id`: warn inline.

Every output continues to the **Soft-Fix Notice**.

### Soft-Fix Notice

Run this on every path, before the Report. Soft-pass review fixes (n1-start SOFT-ONLY pass, recorded as `## Fix Cycle <N> (soft)` in implementation.md) are never re-reviewed. When Codex did not review the branch, the notice discloses them to the human merger as not cross-reviewed. It never blocks.

```bash
source ~/.n1/preamble.sh
ID='<the ticket ID>'
PR_URL='<the PR URL from step 4>'
OUTCOME='<only the word after codex_review_outcome= (ran, skipped, timeout or failed) from Step 9; else empty>'
[ "$OUTCOME" = ran ] && { echo "softfix:reviewed"; exit 0; }
case "${ID:-}" in ''|*[!A-Za-z0-9_-]*) echo "softfix:no-id"; exit 0;; esac
[ -n "${N1_HOME:-}" ] || { echo "softfix:no-id"; exit 0; }
IMPL="$N1_HOME/memory/$ID/implementation.md"
[ -e "$IMPL" ] || { echo "softfix:none"; exit 0; }
grep -qE '^## Fix Cycle [0-9]+ \(soft\)' "$IMPL" 2>/dev/null; RC=$?
[ "$RC" -eq 1 ] && { echo "softfix:none"; exit 0; }
[ "$RC" -eq 0 ] || { echo "softfix:unreadable"; exit 0; }
PR_NUMBER=${PR_URL##*/}
case "$PR_URL" in https://*/pull/*) ;; *) echo "softfix:bad-pr-url"; exit 0;; esac
case "$PR_NUMBER" in ''|*[!0-9]*) echo "softfix:bad-pr-url"; exit 0;; esac
case "$OUTCOME" in skipped|timeout|failed) ;; *) OUTCOME=unknown;; esac
EXISTING=$(timeout -k 5 30 gh pr view "$PR_URL" --json comments --jq '[.comments[].body | select(startswith("## Soft-Pass Fixes Not Cross-Reviewed"))] | length' 2>/dev/null) || EXISTING=0
[ "${EXISTING:-0}" -gt 0 ] 2>/dev/null && { echo "softfix:already-posted"; exit 0; }
mkdir -p "$N1_HOME/scratch"
SOFTFIX_FILE=$(mktemp "$N1_HOME/scratch/codex-softfix-$PR_NUMBER.XXXXXX") || { echo "softfix:comment-failed"; exit 0; }
printf '%s\n\n%s\n' '## Soft-Pass Fixes Not Cross-Reviewed' "Codex review did not run (outcome: $OUTCOME). This branch contains soft-pass review fixes (one developer pass after a review PASS, with no re-review). They are not cross-reviewed: only the full test suite (and CI, if configured) checked them. Review those commits before merging." > "$SOFTFIX_FILE"
timeout -k 5 30 gh pr comment "$PR_URL" --body-file "$SOFTFIX_FILE" >/dev/null 2>&1 && echo "softfix:posted" || echo "softfix:comment-failed"
rm -f "$SOFTFIX_FILE"
```

Replace all three `<...>` placeholders. An unfilled or invalid ID prints `softfix:no-id` (warned). Paste only the outcome word; anything outside the allow-list becomes `unknown`.

If the output says `softfix:comment-failed`, `softfix:bad-pr-url`, `softfix:no-id` or `softfix:unreadable` (implementation.md exists but could not be read, so disclosure status is unknown), warn inline that the soft-pass fixes may not be cross-reviewed and continue. `softfix:already-posted` means an earlier run already posted the notice. A failed comment lookup posts anyway. Every output continues to **Step 10: Report**.

## Step 10: Report

If `qualityEscalations=auto-accept`, never end with an offer or question to fix Codex findings or file follow-ups, whether or not triage ran. Report the persona's counts lines from step 1 only. Unfixed items are in the posted triage comment (or `memory/<ID>/codex-triage.md` if posting failed); never list them from the orchestrator. For Human Review items go through `<N1_ROOT>/references/followup-filing.md` § Append (source `codex`): the triage persona appended them when its report phase ran. Append the one item remembered in step 1 or Step 9 when present (`Codex review findings: see ticket memory codex-review.md`, or `Codex triage not posted: see ticket memory codex-triage.md`). n1-start FINALIZE MEMORY files them; outside n1-start, report them as unfiled.

Every path through Step 9 ends here, whatever the Codex outcome was. Print this report exactly once. It is the end of n1-pr.

Read ticket URL:
```bash
source ~/.n1/preamble.sh
TICKET_URL=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" 2>/dev/null || echo "")
```

Draft mode (**bolded** URL to surface draft state):
```
**PR created (draft):** <PR_URL>
PR #: <number>
Title: <title>
Base: <default branch>
Tracker: <status updated / not configured / failed>
<Ticket: <TICKET_URL> — omit line if empty>
CHECKPOINT: Ready for Tech Lead review.
```

Ready mode: same with `PR created:` (not bolded).
