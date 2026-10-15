# Procedure: Reconcile PR Body

Rewrites an open PR's whole description after pushes made once the PR exists, so every claim matches the current diff. Called once at the end of a run by n1-ci (Step 4 / Step 7a), the n1-pr Codex triage fix cycle (Step 9), and n1-review-response (Step 6a). It is also used for ad-hoc pushes outside a skill run (HOST ROUTING `PR BODY RECONCILE`). It never commits or pushes. It never blocks: any failure prints a `reconcile:failed` or `reconcile:aborted` line, the PR body may be stale, and the caller continues. It needs no Decision Ledger row.

**Run-start contract.** Before its first developer dispatch, each calling site records the PR head:

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
mkdir -p "$N1_HOME/scratch"
gh pr view "$PR_NUMBER" --json headRefOid --jq .headRefOid > "$N1_HOME/scratch/reconcile-start-$PR_NUMBER.sha" 2>/dev/null || true
```

The file is keyed by PR number because standalone runs may have no ticket ID. § Check consumes it, so a second pass in the same run and a stale file both resolve to a skip only when the head did not move.

**Ad-hoc pushes** (outside any N1 skill run): run § Check with `ADHOC=1`, then § Dispatch with a short summary of what you pushed as the fix report, then § Apply.

## § Check

Prints `reconcile:skip` when the PR is not open, when (not ad-hoc) there is no start SHA or the head did not move, or when (ad-hoc) the PR author isn't you. Otherwise it stages the inputs and prints `reconcile:run dir=<D>`.

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
ADHOC="<1 for an ad-hoc push outside a skill run, else empty>"
if [ -n "$ADHOC" ]; then
  START=""
else
  F="$N1_HOME/scratch/reconcile-start-$PR_NUMBER.sha"
  START=$(cat "$F" 2>/dev/null); rm -f "$F"
  case "$START" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) START="" ;;
  esac
fi
read -r NOW STATE AUTHOR < <(gh pr view "$PR_NUMBER" --json headRefOid,state,author --jq '"\(.headRefOid) \(.state) \(.author.login)"' 2>/dev/null)
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
```

`reconcile:skip` → stop here silently (no dispatch, no edit). `reconcile:failed:fetch` → warn and stop. The ad-hoc path never reads or deletes the start-SHA file, so it can't consume the file of an in-progress skill run on the same PR.

## § Dispatch

Only after `reconcile:run`. Dispatch persona tech-writer (resolve model for `tech-writer`) with:
- `mode: reconcile`
- `old body: <D>/old-body.md`, `diff: <D>/diff.patch`, `commits: <D>/commits.txt`
- `fix report:` the developer output(s) from this run, verbatim, in whatever shape the caller has (`## CI Fixes Applied`, `## Codex Review Fixes`, `## Review Fixes Applied`, or an ad-hoc summary)
- `output: <D>/new-body.md`

`<D>` is the directory from the `reconcile:run dir=<D>` line; use that exact value here and in § Apply.

Wait for it to return. Do not read, edit, or echo the body text yourself. The body goes from tech-writer's file to `gh pr edit --body-file` untouched, so untrusted text is never quoted into a shell command. If the dispatch fails or times out, still run § Apply: it reports `reconcile:failed:empty` and cleans up. tech-writer's return lists any Deployment Actions items it newly appended (or "none") — carry that list into the final report line below.

## § Apply

Refuses a revised body that drops any `- [x]` line or any `## Deployment Actions` checkbox line from the old body (appending new unticked actions is fine), then posts it. Always removes `<D>`.

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
D="<D from the reconcile:run line>"
if [ ! -s "$D/new-body.md" ]; then
  echo "reconcile:failed:empty — PR body reconcile failed, body may be stale"
else
  tr -d '\r' < "$D/new-body.md" > "$D/new.lf"
  MISSING=$(awk '/^## /{da = ($0 ~ /^## Deployment Actions[[:space:]]*$/)} /^[[:space:]]*- \[[xX]\] / || (da && /^[[:space:]]*- \[ \] /)' "$D/old-body.md" \
    | while IFS= read -r l; do grep -qxF -- "$l" "$D/new.lf" || printf '%s\n' "$l"; done)
  if [ -n "$MISSING" ]; then
    echo "reconcile:aborted — revised body dropped preserved lines; PR body left unchanged:"; printf '%s\n' "$MISSING"
  elif gh pr edit "$PR_NUMBER" --body-file "$D/new.lf" >/dev/null 2>&1; then
    echo "reconcile:applied:#$PR_NUMBER"
  else
    echo "reconcile:failed:edit — PR body reconcile failed, body may be stale"
  fi
fi
rm -rf "$D"
```

Report one line in the caller's final report: `PR body: reconciled` (`applied`, appending `— new deploy actions: <items>` when tech-writer listed any), `PR body: unchanged` (`skip`), or `PR body: may be stale — <reason>` (`failed`/`aborted`, listing the dropped lines for `aborted`).
