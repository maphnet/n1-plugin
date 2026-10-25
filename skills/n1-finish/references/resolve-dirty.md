# Resolve a DIRTY PR (mergeOnFinish)

Reached from Step 2 § 3.1 on the first `state:DIRTY` of an n1-finish run with `merge-on-finish:yes`. Rebases the PR branch onto its base in the current checkout, resolves version-manifest conflicts mechanically, hands other conflicts to the developer persona, pushes with a pinned lease, advances the reviewed-head pin, waits for CI, then re-runs 3.1. One attempt per run. Queue and headless runs never reach this file, and every writing block re-checks that.

Each **STOP** below ends the run with the quoted message. Nothing is pushed before § Push, and every failure before it leaves the branch at the reviewed head.

Version manifests (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`) are resolved mechanically only when the repo has both plus `scripts/bump-version.sh` (N1's own layout; the script is not executable in git, so it is run with `bash`); elsewhere every conflict goes to the developer persona. When the PR changed nothing but the version in the manifests, a manifest conflict takes the base branch's side; otherwise it goes to the developer persona. Then one `chore: bump version to <new> (<ID>)` commit sets a version strictly above the base's, in the same class (major / minor / patch) as the PR's original bump.

## § Resolve

One shell call in the current checkout. `<n>` is the PR number, `<head>` the reviewed-head pin from 3.1, `<id>` the ticket ID, `<dev>` `0` on the first call and `1` after the developer round, `<stop>` and `<snap>` empty on the first call and the `stop=` and `snap=` values of `resolve:conflicts` after it.

```bash
source ~/.n1/preamble.sh
[ "$(n1_finish_merge_enabled)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo resolve:denied; exit 1; }
N="<n>"; H="<head>"; ID="<id>"; DEV="<dev>"; S0="<stop>"; SN="<snap>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$H" =~ ^[0-9a-f]{40}$ ]] && [[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$DEV" =~ ^[01]$ ]] && [[ "$S0" =~ ^([0-9a-f]{40})?$ ]] && [[ "$SN" =~ ^([0-9a-f]{40})?$ ]] || { echo arg:invalid; exit 1; }
PJ=.claude-plugin/plugin.json; MJ=.claude-plugin/marketplace.json; OLD=
skip() { if [ "$DEV" = 1 ] && RD=$(rip) && [ "$(cat "$RD/orig-head" 2>/dev/null)" = "$H" ]; then git rebase --abort >/dev/null 2>&1; fi; echo "resolve:skip $1"; exit 1; }
abort() { git rebase --abort >/dev/null 2>&1; [ "$(git rev-parse HEAD)" = "$OLD" ] || git reset -q --hard "$OLD"; echo "resolve:abort $1 files:${2:-}"; exit 1; }
rip() { local d p; for d in rebase-merge rebase-apply; do p=$(git rev-parse --git-path "$d"); [ -d "$p" ] && { echo "$p"; return 0; }; done; return 1; }
snap() { { cat "$RD/n1-conflicts" "$RD/git-rebase-todo" "$RD/done"; git ls-files -s | awk -F'\t' 'NR==FNR{u[$0]=1;next} !($2 in u)' "$RD/n1-conflicts" -; } 2>/dev/null | git hash-object --stdin; }
unm() { git diff --no-color --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ $//'; }
ver() { git show --no-color "$1:$PJ" 2>/dev/null | jq -r '.version // empty' 2>/dev/null; }
xyz() { [[ "$1" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){2}$ ]]; }
gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]; }
read -r BR BASE XR < <(gh pr view "$N" --json headRefName,baseRefName,isCrossRepository -q '[.headRefName,.baseRefName,(.isCrossRepository|tostring)]|join(" ")' 2>/dev/null)
[ -n "$BR" ] && [ -n "$BASE" ] || skip pr-view
[ "$XR" = false ] && [ "$BR" != "$BASE" ] || skip fork
[[ "$BASE" != -* ]] && git check-ref-format --branch "$BASE" >/dev/null 2>&1 || skip base
[ "$(n1_review_pin get "$N")" = "$H" ] || skip pin
if RD=$(rip); then
  [ "$DEV" = 1 ] || skip rebase-in-progress
  [ "$(cat "$RD/head-name" 2>/dev/null)" = "refs/heads/$BR" ] || skip branch
  OLD=$(cat "$RD/orig-head" 2>/dev/null); [ "$OLD" = "$H" ] || skip rebase-not-ours
  [ "$(git rev-parse HEAD)" = "$S0" ] && [ "$(cat "$RD/onto" 2>/dev/null)" = "$(git rev-parse "origin/$BASE")" ] && [ -n "$SN" ] && [ "$(snap)" = "$SN" ] || abort scope
else
  [ "$(git symbolic-ref -q --short HEAD)" = "$BR" ] || skip branch
  OLD=$(git rev-parse HEAD); [ "$OLD" = "$H" ] || skip local-tip
  [ -z "$(git status --porcelain --untracked-files=no)" ] || skip dirty
  git fetch -q origin -- "$BASE" 2>/dev/null || skip fetch
fi
VM=0; PO=0; [ -f scripts/bump-version.sh ] && [ -f "$PJ" ] && [ -f "$MJ" ] && VM=1
if [ "$VM" = 1 ]; then
  MB=$(git merge-base "$OLD" "origin/$BASE"); B=$(ver "$MB"); P=$(ver "$OLD"); M=$(ver "origin/$BASE")
  xyz "$B" && xyz "$P" && xyz "$M" || abort version "$B/$P/$M"
  nov() { { git show --no-color "$1:$PJ" | jq -S 'del(.version)'; git show --no-color "$1:$MJ" | jq -S 'del(.plugins[0].version)'; } 2>/dev/null; }
  [ "$(nov "$MB")" = "$(nov "$OLD")" ] && PO=1
fi
[ -n "$RD" ] || git rebase -q "origin/$BASE" >/dev/null 2>&1
i=0
while RD=$(rip); do
  i=$((i+1)); [ "$i" -le 20 ] || abort loop-cap "$(unm)"
  U=$(unm)
  if [ -n "$U" ]; then
    if [ "$PO" = 1 ] && [ -z "$(git diff --no-color --name-only --diff-filter=U | grep -vxF -e "$PJ" -e "$MJ")" ]; then
      git checkout -q --ours -- $U && git add -- $U || abort checkout "$U"
    elif [ "$DEV" = 1 ]; then abort conflicts "$U"
    else git diff --no-color --name-only --diff-filter=U > "$RD/n1-conflicts"; echo "resolve:conflicts old=$OLD stop=$(git rev-parse HEAD) snap=$(snap) files:$U"; exit 1
    fi
  fi
  if git diff --no-color --cached --quiet; then git rebase --skip >/dev/null 2>&1; else GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; fi
done
git merge-base --is-ancestor "origin/$BASE" HEAD || abort not-rebased "$(unm)"
git diff --no-color --text --no-textconv --no-ext-diff -U0 "origin/$BASE" HEAD | grep -qE '^\+(<<<<<<<|>>>>>>>)( |$)' && abort markers "$(git diff --no-color --name-only "origin/$BASE" HEAD | tr '\n' ' ')"
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
- `resolve:skip <reason>` (wrong branch, fork PR or head branch equal to base, unusable base name, uncommitted changes, local tip or pin not at the reviewed head, fetch failed, a rebase already in progress, already up to date) → "PR #<n> cannot merge yet (conflicts; auto-resolve skipped: <reason>). Fix that, then re-run `/n1:n1-finish`." **STOP.** Nothing was changed (a rebase left by the developer round is aborted first).
- `resolve:abort <reason> files:<list>` → "Could not resolve the conflicts of PR #<n> automatically (<reason>: <list>). The branch is back at the reviewed head and nothing was pushed. Rebase it onto the base branch yourself, then re-run `/n1:n1-finish`." Add the developer's `CANNOT_RESOLVE` reason when there is one. **STOP.**
- `resolve:conflicts old=<sha> stop=<sha> snap=<sha> files:<list>` → § Developer.
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

Then run § Resolve again with `<dev>` = `1` and `<stop>` = the `stop=` SHA and `<snap>` = the `snap=` value, whatever the developer reported: an unresolved file is still unmerged (or still has markers), so the block aborts and restores the reviewed head. The `snap=` value hashes the exact conflict list, the rebase todo and `done` files, and every staged entry outside the conflict list. The block aborts (`scope`) unless HEAD is still at `stop=`, the base is unchanged and that hash still matches: the developer may change only the conflict files, and any commit, todo edit, restarted rebase or edit, addition, deletion or rename of another path aborts.

## § Tests

After `resolve:ready`: run the project test suite in the current checkout, discovered as in Step 2b.3 (no test configuration found: note "no test suite detected" and continue). Non-zero exit → run `git reset -q --hard <old>` (nothing was pushed), report the failure output and "Tests fail after rebasing PR #<n> onto its base. The branch is back at the reviewed head. Resolve it yourself, then re-run `/n1:n1-finish`." **STOP.** Pass → § Push.

## § Push

One shell call. `<old>` and `<new>` come from `resolve:ready`. The lease is pinned to the reviewed head, so the push fails if anyone moved the remote branch since review.

```bash
source ~/.n1/preamble.sh
[ "$(n1_finish_merge_enabled)" = true ] && [ -z "${N1_QUEUE_RUN_ID:-}" ] && [ "${N1_HEADLESS:-}" != 1 ] || { echo resolve:denied; exit 1; }
N="<n>"; OLD="<old>"; NEW="<new>"
case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
[[ "$OLD" =~ ^[0-9a-f]{40}$ ]] && [[ "$NEW" =~ ^[0-9a-f]{40}$ ]] || { echo sha:invalid; exit 1; }
read -r BR BASE XR < <(gh pr view "$N" --json headRefName,baseRefName,isCrossRepository -q '[.headRefName,.baseRefName,(.isCrossRepository|tostring)]|join(" ")' 2>/dev/null)
[ -n "$BR" ] && [ -n "$BASE" ] && [ "$XR" = false ] && [ "$BR" != "$BASE" ] && [ "$(git symbolic-ref -q --short HEAD)" = "$BR" ] && [ "$(git rev-parse HEAD)" = "$NEW" ] || { echo push:skip; exit 1; }
[ "$(n1_review_pin get "$N")" = "$OLD" ] || { echo pin:moved; exit 1; }
git push -q --force-with-lease="$BR:$OLD" origin "$BR" 2>&1 || { echo push:rejected; exit 1; }
echo "pushed:${NEW:0:7}"
n1_review_pin advance "$N" "$OLD" "$NEW"
```

- `resolve:denied` → "Merge is not authorized in this run." **STOP.** `pr:invalid` / `sha:invalid` → report it. **STOP.**
- `push:skip` (branch or local tip changed since § Resolve) → "PR #<n> was rebased locally but not pushed: the checkout changed. Re-run `/n1:n1-finish`." **STOP.**
- `pin:moved` → "The reviewed-head pin of PR #<n> changed during the resolve; nothing was pushed. Re-run `/n1:n1-finish`." **STOP.**
- `push:rejected` → "The push of the rebased PR #<n> was rejected: the remote branch moved since review. The remote is unchanged; the local branch holds the rebased commits (`git reset --hard <old>` restores the reviewed head). Review the remote commits, then re-run `/n1:n1-finish`." **STOP.**
- `pushed:` followed by `pin:kept` or `pin:unavailable` → "PR #<n> was pushed at <first 7 of new>, but the reviewed-head pin was not advanced, so N1 will not merge it. Review it (`/n1:n1-review`), then merge it yourself and re-run `/n1:n1-finish`." **STOP.**
- `pin:advanced <sha7>` → § CI wait. Developer-resolved and version-only resolutions both advance the pin: N1 reviewed the rewrite here (mechanical bump, or the developer round plus tests), same as the n1-ci fix-push precedent.

## § CI wait

One shell call; run it with the maximum (10-minute) tool timeout: it polls for up to 8 minutes.

```bash
source ~/.n1/preamble.sh
N="<n>"; case "$N" in ""|*[!0-9]*) echo pr:invalid; exit 1;; esac
WF=0; grep -qsE 'pull_request' "$(git rev-parse --show-toplevel)/.github/workflows/"*.y*ml && WF=1
R=timeout; S=; CP=0
for _ in $(seq "${RESOLVE_CI_POLLS:-24}"); do
  sleep "${RESOLVE_CI_SLEEP:-20}"; CP=0
  C=$(gh pr checks "$N" --json bucket --jq '"fail="+([.[]|select(.bucket=="fail" or .bucket=="cancel")]|length|tostring)+" pending="+([.[]|select(.bucket=="pending")]|length|tostring)' 2>&1)
  case "$C" in
    "fail=0 pending=0") CP=1 ;;
    *"no checks reported"*) [ "$WF" = 1 ] || CP=1 ;;
    "fail=0 "*) ;;
    fail=[1-9]*) R=fail; break ;;
  esac
  [ "$CP" = 1 ] || continue
  S=$(gh pr view "$N" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null)
  case "$S" in ""|UNKNOWN) ;; *) R=pass; break ;; esac
done
[ "$R" = timeout ] && [ "$CP" = 1 ] && R=pass
echo "ci:$R"; echo "state:$S"
```

No checks yet with a `pull_request` workflow, and API errors, count as pending. Green checks with `mergeStateStatus` still `UNKNOWN` at the end count as `ci:pass` (3.1 treats `UNKNOWN` as continue; `--match-head-commit` in 3.4 is the backstop).

- `ci:fail` → "CI is failing on PR #<n> after the conflict-resolution push. Fix CI, then re-run `/n1:n1-finish`." **STOP.**
- `ci:timeout` → "CI still running after the resolve push; re-run `/n1:n1-finish`." **STOP.**
- `ci:pass` → § Re-check.

## § Re-check

Run the 3.1 pre-merge block again and apply every line, with this run's resolve attempt counted: a second `state:DIRTY` is a **STOP** (another PR landed first). The pin now equals the pushed head, so `<head>` for 3.2 and 3.4 is `<new>`. A threads answer already given in this run carries over when the count is unchanged. The `codex:` line is unaffected (Codex receipts are per session, not per head) and no new Codex review is required.
