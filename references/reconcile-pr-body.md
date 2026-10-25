# Procedure: Reconcile PR Body

Rewrites an open PR's whole description after pushes made once the PR exists, so every claim matches the current diff. Called once at the end of a run by n1-ci (Step 4 / Step 7a), the n1-pr Codex triage fix cycle (Step 9), and n1-review-response (Step 6a). It is also used for ad-hoc pushes outside a skill run (HOST ROUTING `PR BODY RECONCILE`). It never commits or pushes; its only state change besides the PR body is advancing the reviewed-head pin in § Check. It never blocks: any failure prints a `reconcile:failed` or `reconcile:aborted` line, the PR body may be stale, and the caller continues. It needs no Decision Ledger row.

**Run-start contract.** Before its first developer dispatch, each calling site records the PR head in its own file and carries the path forward, the same way `<D>` is carried from the `reconcile:run dir=` line:

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
mkdir -p "$N1_HOME/scratch"
find "$N1_HOME/scratch" -maxdepth 1 -name 'reconcile-start-*' -mtime +1 -delete 2>/dev/null
F=$(mktemp "$N1_HOME/scratch/reconcile-start-$PR_NUMBER.XXXXXX")
gh pr view "$PR_NUMBER" --json headRefOid --jq .headRefOid > "$F" 2>/dev/null || true
echo "reconcile:start file=$F"
```

Each run gets its own file (a per-PR name would collide across overlapping runs on the same PR), so it is keyed by PR number plus a random suffix; standalone runs may have no ticket ID to key on instead. The capture snippet also prunes start files older than a day left behind by crashed runs. § Check takes the exact path printed after `file=` and consumes it (reads then deletes), so a second pass in the same run and a stale file both resolve to a skip only when the head did not move.

**Ad-hoc pushes** (outside any N1 skill run): run § Check with `ADHOC=1`, then § Dispatch with a short summary of what you pushed as the fix report, then § Apply.

## § Check

Prints `reconcile:skip` when the PR is not open, when (not ad-hoc) there is no start SHA or the head did not move, or when (ad-hoc) the PR author isn't you. Otherwise it stages the inputs and prints `reconcile:run dir=<D>`.

When a skill run moved the head of an open PR, it first runs `n1_review_pin advance` (N1-141): the reviewed-head pin that n1-finish merges follows the push only when the run started at the pinned head and the new head is the local tip of the PR branch (a commit N1 pushed), so a push by anyone else, before or during the run, or a run that pushed nothing, keeps the old pin and n1-finish refuses to merge. Ad-hoc runs never advance it. The `pin:advanced <sha7>` / `pin:kept` / `pin:unavailable` line is informational and never blocks.

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
ADHOC="<1 for an ad-hoc push outside a skill run, else empty>"
START_FILE="<F from the reconcile:start line, empty for ad-hoc>"
if [ -n "$ADHOC" ]; then
  START=""
else
  START=$(cat "$START_FILE" 2>/dev/null); rm -f "$START_FILE"
  case "$START" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) START="" ;;
  esac
fi
if ! META=$(gh pr view "$PR_NUMBER" --json headRefOid,state,author --jq '"\(.headRefOid) \(.state) \(.author.login)"' 2>/dev/null) || [ -z "$META" ]; then
  echo "reconcile:failed:fetch — PR body reconcile failed, body may be stale"
else
  read -r NOW STATE AUTHOR <<<"$META"
  [ -z "$ADHOC" ] && [ "${STATE:-}" = OPEN ] && [ -n "$START" ] && [ "$START" != "${NOW:-}" ] && n1_review_pin advance "$PR_NUMBER" "$START" "$NOW"
  if [ -n "$ADHOC" ] && [ "$AUTHOR" != "$(gh api user --jq .login 2>/dev/null)" ]; then
    echo "reconcile:skip — not your PR"
  elif [ "${STATE:-}" != "OPEN" ] || [ -z "${NOW:-}" ] || { [ -z "$ADHOC" ] && { [ -z "$START" ] || [ "$START" = "$NOW" ]; }; }; then
    echo "reconcile:skip"
  elif ! BODY=$(gh pr view "$PR_NUMBER" --json body --jq .body 2>/dev/null); then
    echo "reconcile:failed:fetch — PR body reconcile failed, body may be stale"
  else
    mkdir -p "$N1_HOME/scratch"
    D=$(mktemp -d "$N1_HOME/scratch/reconcile-$PR_NUMBER.XXXXXX")
    if ! gh pr diff "$PR_NUMBER" > "$D/diff.patch" 2>/dev/null || [ ! -s "$D/diff.patch" ]; then
      rm -rf "$D"
      echo "reconcile:failed:fetch — PR body reconcile failed, body may be stale"
    else
      printf '%s\n' "$BODY" | tr -d '\r' > "$D/old-body.md"
      cp "$D/diff.patch" "$D/diff-full.patch"
      B=$(wc -c < "$D/diff.patch" | tr -d ' ')
      if [ "$B" -gt 30000 ]; then
        head -c 30000 "$D/diff.patch" > "$D/diff.tmp"
        printf '\n[truncated: first 30KB of %sB shown]\n' "$B" >> "$D/diff.tmp"; mv "$D/diff.tmp" "$D/diff.patch"
      fi
      if ! { [ -n "$START" ] && [ "$START" != "$NOW" ] && gh api "repos/{owner}/{repo}/compare/$START...$NOW" --jq '.commits[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"' > "$D/commits.txt" 2>/dev/null && [ -s "$D/commits.txt" ]; }; then
        gh pr view "$PR_NUMBER" --json commits --jq '.commits[] | "\(.oid[0:7]) \(.messageHeadline)"' > "$D/commits.txt" 2>/dev/null
      fi
      echo "reconcile:run dir=$D"
    fi
  fi
fi
```

`reconcile:skip` → stop here silently (no dispatch, no edit). `reconcile:failed:fetch` → warn and stop; the metadata fetch failure still consumes (reads and deletes) `START_FILE` above so it can't leak into a later run. The ad-hoc path never reads or deletes the start file, so it can't consume the file of an in-progress skill run on the same PR.

## § Dispatch

Only after `reconcile:run`. Dispatch persona tech-writer (resolve model for `tech-writer`) with:
- `mode: reconcile`
- `old body: <D>/old-body.md`, `diff: <D>/diff.patch`, `full diff: <D>/diff-full.patch`, `commits: <D>/commits.txt`
- `fix report:` the developer output(s) from this run, verbatim, in whatever shape the caller has (`## CI Fixes Applied`, `## Codex Review Fixes`, `## Review Fixes Applied`, or an ad-hoc summary)
- `output: <D>/new-body.md`

`<D>` is the directory from the `reconcile:run dir=<D>` line; use that exact value here and in § Apply.

Wait for it to return. Do not read, edit, or echo the body text yourself. The body goes from tech-writer's file to `gh pr edit --body-file` untouched, so untrusted text is never quoted into a shell command. If the dispatch fails or times out, still run § Apply: it reports `reconcile:failed:empty` and cleans up. tech-writer's return lists any Deployment Actions items it newly appended (or "none") — carry that list into the final report line below.

## § Apply

Refuses a revised body that drops or changes any `## Deployment Actions` checkbox line, or any line carrying `*(locally verified — ...)*`, `*(local testing: FAILED — ...)*`, or `*(manual check)*` — that frozen set must be copied byte-for-byte (appending new unticked Deployment Actions is fine). Plain `- [x]` lines outside that frozen set may be reworded when the diff makes their facts stale, but the total count of `- [x]`/`- [X]` lines must not drop, so a plain ticked line can be reworded but never unticked or dropped. Re-fetches the live PR body right before posting and aborts if it no longer matches `old-body.md` (someone else edited the PR description mid-reconcile) or the re-fetch fails. Always removes `<D>`.

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
D="<D from the reconcile:run line>"
if [ ! -s "$D/new-body.md" ]; then
  echo "reconcile:failed:empty — PR body reconcile failed, body may be stale"
else
  tr -d '\r' < "$D/new-body.md" | sed -e '${/^[[:space:]]*<\/content>[[:space:]]*$/d;}' > "$D/new.lf"
  MISSING=$(awk '/^## /{da = ($0 ~ /^## Deployment Actions[[:space:]]*$/)} (da && /^[[:space:]]*- \[[ xX]\] /) || /\*\(locally verified —/ || /\*\(local testing: FAILED —/ || /\*\(manual check\)\*/' "$D/old-body.md" \
    | while IFS= read -r l; do grep -qxF -- "$l" "$D/new.lf" || printf '%s\n' "$l"; done)
  OLD_TICKS=$(grep -cE '^[[:space:]]*- \[[xX]\] ' "$D/old-body.md")
  NEW_TICKS=$(grep -cE '^[[:space:]]*- \[[xX]\] ' "$D/new.lf")
  if [ -n "$MISSING" ]; then
    echo "reconcile:aborted — revised body dropped preserved lines; PR body left unchanged:"; printf '%s\n' "$MISSING"
  elif [ "$NEW_TICKS" -lt "$OLD_TICKS" ]; then
    echo "reconcile:aborted — revised body unticked or dropped checked items; PR body left unchanged"
  elif ! CURRENT=$(gh pr view "$PR_NUMBER" --json body --jq .body 2>/dev/null); then
    echo "reconcile:aborted — PR body changed during reconcile; left unchanged"
  else
    printf '%s\n' "$CURRENT" | tr -d '\r' > "$D/current-body.md"
    if ! cmp -s "$D/old-body.md" "$D/current-body.md"; then
      echo "reconcile:aborted — PR body changed during reconcile; left unchanged"
    elif gh pr edit "$PR_NUMBER" --body-file "$D/new.lf" >/dev/null 2>&1; then
      echo "reconcile:applied:#$PR_NUMBER"
    else
      echo "reconcile:failed:edit — PR body reconcile failed, body may be stale"
    fi
  fi
fi
rm -rf "$D"
```

A trailing `</content>` wrapper line (if tech-writer's output tool appended one) is stripped during normalization; a `</content>` line anywhere else in the body is left alone. Re-fetching and comparing the live body just before the edit catches someone else editing the PR description mid-reconcile; a changed or unreadable body aborts without writing. Report one line in the caller's final report: `PR body: reconciled` (`applied`, appending `— new deploy actions: <items>` when tech-writer listed any), `PR body: unchanged` (`skip`), or `PR body: may be stale — <reason>` (`failed`/`aborted`, listing the dropped lines, the unticked/dropped-item reason, or the concurrent-edit reason for `aborted`).
