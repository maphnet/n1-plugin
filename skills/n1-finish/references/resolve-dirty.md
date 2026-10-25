# Resolve a DIRTY PR (mergeOnFinish)

Reached from Step 2 § 3.1 on the first `state:DIRTY` of an n1-finish run with `merge-on-finish:yes`. Rebases the PR branch onto its base in the current checkout, resolves version-manifest conflicts mechanically, hands other conflicts to the developer persona, pushes with a pinned lease, advances the reviewed-head pin, waits for CI, then re-runs 3.1. One attempt per run. Queue and headless runs never reach this file, and every writing block re-checks that.

Each **STOP** below ends the run with the quoted message. Nothing is pushed before § Push, and every failure before it leaves the branch at the reviewed head.

Version manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) are resolved mechanically only when the repo has both plus `scripts/bump-version.sh` (N1's own layout; the script is not executable in git, so it is run with `bash`); elsewhere every conflict goes to the developer persona. A manifest conflict takes the base branch's side, then one `chore: bump version to <new> (<ID>)` commit sets a version strictly above the base's, in the same class (major / minor / patch) as the PR's original bump.

## § Resolve

One shell call in the current checkout. `<n>` is the PR number, `<head>` the reviewed-head pin from 3.1, `<id>` the ticket ID, `<dev>` `0` on the first call and `1` after the developer round.

```bash
source ~/.n1/preamble.sh
[ "$(n1_finish_merge_enabled)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo resolve:denied; exit 1; }
N="<n>"; H="<head>"; ID="<id>"; DEV="<dev>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$H" =~ ^[0-9a-f]{40}$ ]] && [[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$DEV" =~ ^[01]$ ]] || { echo arg:invalid; exit 1; }
PJ=.claude-plugin/plugin.json; MJ=.claude-plugin/marketplace.json; OLD=
skip() { echo "resolve:skip $1"; exit 1; }
abort() { git rebase --abort >/dev/null 2>&1; [ "$(git rev-parse HEAD)" = "$OLD" ] || git reset -q --hard "$OLD"; echo "resolve:abort $1 files:${2:-}"; exit 1; }
rip() { local d p; for d in rebase-merge rebase-apply; do p=$(git rev-parse --git-path "$d"); [ -d "$p" ] && { echo "$p"; return 0; }; done; return 1; }
unm() { git diff --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ $//'; }
ver() { git show "$1:$PJ" 2>/dev/null | jq -r '.version // empty' 2>/dev/null; }
xyz() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
read -r BR BASE < <(gh pr view "$N" --json headRefName,baseRefName -q '.headRefName+" "+.baseRefName' 2>/dev/null)
[ -n "$BR" ] && [ -n "$BASE" ] || skip pr-view
[ "$(n1_review_pin get "$N")" = "$H" ] || skip pin
if RD=$(rip); then
  [ "$DEV" = 1 ] || skip rebase-in-progress
  [ "$(cat "$RD/head-name" 2>/dev/null)" = "refs/heads/$BR" ] || skip branch
  OLD=$(cat "$RD/orig-head" 2>/dev/null); [ "$OLD" = "$H" ] || skip rebase-not-ours
else
  [ "$(git symbolic-ref -q --short HEAD)" = "$BR" ] || skip branch
  OLD=$(git rev-parse HEAD); [ "$OLD" = "$H" ] || skip local-tip
  [ -z "$(git status --porcelain --untracked-files=no)" ] || skip dirty
  git fetch -q origin "$BASE" 2>/dev/null || skip fetch
fi
VM=0; [ -f scripts/bump-version.sh ] && [ -f "$PJ" ] && [ -f "$MJ" ] && VM=1
if [ "$VM" = 1 ]; then
  B=$(ver "$(git merge-base "$OLD" "origin/$BASE")"); P=$(ver "$OLD"); M=$(ver "origin/$BASE")
  xyz "$B" && xyz "$P" && xyz "$M" || abort version "$B/$P/$M"
fi
[ -n "$RD" ] || git rebase -q "origin/$BASE" >/dev/null 2>&1
i=0
while RD=$(rip); do
  i=$((i+1)); [ "$i" -le 20 ] || abort loop-cap "$(unm)"
  U=$(unm)
  if [ -n "$U" ]; then
    if [ "$VM" = 1 ] && [ -z "$(git diff --name-only --diff-filter=U | grep -vxF -e "$PJ" -e "$MJ")" ]; then
      git checkout -q --ours -- $U && git add -- $U || abort checkout "$U"
    elif [ "$DEV" = 1 ]; then abort conflicts "$U"
    else echo "resolve:conflicts old=$OLD files:$U"; exit 1
    fi
  fi
  git diff --cached -U0 | grep -qE '^\+(<<<<<<<|>>>>>>>)( |$)' && abort markers "$(git diff --cached --name-only | tr '\n' ' ')"
  if git diff --cached --quiet; then git rebase --skip >/dev/null 2>&1; else GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; fi
done
git merge-base --is-ancestor "origin/$BASE" HEAD || abort not-rebased "$(unm)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || abort dirty
NV=none
if [ "$VM" = 1 ]; then
  V=$(jq -r .version "$PJ"); K=$(jq -r '.plugins[0].version' "$MJ")
  if ! { [ "$V" = "$K" ] && gt "$V" "$M"; }; then
    IFS=. read -r b1 b2 _ <<<"$B"; IFS=. read -r p1 p2 _ <<<"$P"; IFS=. read -r m1 m2 m3 <<<"$M"
    if [ "$p1" -gt "$b1" ]; then NV="$((m1+1)).0.0"; elif [ "$p1" = "$b1" ] && [ "$p2" -gt "$b2" ]; then NV="$m1.$((m2+1)).0"; else NV="$m1.$m2.$((m3+1))"; fi
    bash scripts/bump-version.sh "$NV" >/dev/null && git commit -qam "chore: bump version to $NV ($ID)" || abort bump "$PJ $MJ"
    V=$(jq -r .version "$PJ"); K=$(jq -r '.plugins[0].version' "$MJ")
  fi
  [ "$V" = "$K" ] && gt "$V" "$M" || abort version "$V/$K/$M"
fi
[ "$(git rev-parse HEAD)" != "$OLD" ] || skip up-to-date
echo "resolve:ready old=$OLD new=$(git rev-parse HEAD) bumped=$NV"
```

- `resolve:denied` → "Merge is not authorized in this run." **STOP.**
- `pr:invalid` / `arg:invalid` → report it. **STOP.**
- `resolve:skip <reason>` (wrong branch, uncommitted changes, local tip or pin not at the reviewed head, fetch failed, a rebase already in progress, already up to date) → "PR #<n> cannot merge yet (conflicts; auto-resolve skipped: <reason>). Fix that, then re-run `/n1:n1-finish`." **STOP.** Nothing was changed.
- `resolve:abort <reason> files:<list>` → "Could not resolve the conflicts of PR #<n> automatically (<reason>: <list>). The branch is back at the reviewed head and nothing was pushed. Rebase it onto the base branch yourself, then re-run `/n1:n1-finish`." Add the developer's `CANNOT_RESOLVE` reason when there is one. **STOP.**
- `resolve:conflicts old=<sha> files:<list>` → § Developer.
- `resolve:ready old=<old> new=<new> bumped=<v|none>` → § Tests.

## § Developer

Only after `resolve:conflicts`, and at most once per run. The orchestrator never edits files here. Resolve the model for `developer`, then dispatch persona developer with the conflict file list, the PR number and branch, the ticket memory directory path (absolute), and these instructions:

```
A rebase of the PR branch onto its base is in progress in <current checkout path>, with conflicts in: <files>.
Resolve the conflict markers in those files so that both sides' intent is kept, then `git add` each one.
Run the project test suite.
Do not commit, do not run `git rebase --continue`, `--skip` or `--abort`, do not push, do not change other files.
If a file cannot be resolved mechanically (the two sides change behavior in incompatible ways, or the right result needs a product decision), leave it unresolved and report CANNOT_RESOLVE with the reason.
Output: ## Conflict Resolution, then one line per file: <file>: <resolution summary> | CANNOT_RESOLVE: <reason>; then the test command and its result.
```

Then run § Resolve again with `<dev>` = `1`, whatever the developer reported: an unresolved file is still unmerged (or still has markers), so the block aborts and restores the reviewed head.

## § Tests

After `resolve:ready`: run the project test suite in the current checkout, discovered as in Step 2b.3 (no test configuration found: note "no test suite detected" and continue). Non-zero exit → run `git reset -q --hard <old>` (nothing was pushed), report the failure output and "Tests fail after rebasing PR #<n> onto its base. The branch is back at the reviewed head. Resolve it yourself, then re-run `/n1:n1-finish`." **STOP.** Pass → § Push.
