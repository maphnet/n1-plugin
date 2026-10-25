#!/usr/bin/env bash
# N1-140: n1-finish Step 2 merge-on-finish snippets (pre-merge checks, merge) run against a fake gh.
set -uo pipefail
unset N1_QUEUE_RUN_ID N1_HEADLESS N1_RUN_ID
cd "$(dirname "$0")/.."
ROOT=$(pwd)
F=skills/n1-finish/steps/02-merge.md
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else no "$1"; fi; }
line() { if grep -qxF -- "$2" <<<"$OUT"; then ok "$1"; else no "$1"; fi; }

# Static: no auto-merge, no remote-branch deletion; the queue STOP comes before the merge.
if grep -qE -- '--auto|--delete-branch' "$F"; then no "02-merge has no --auto/--delete-branch"; else ok "02-merge has no --auto/--delete-branch"; fi
Q=$(grep -n 'queue-run:yes' "$F" | head -1 | cut -d: -f1); M=$(grep -n 'gh pr merge' "$F" | head -1 | cut -d: -f1)
if [ -n "$Q" ] && [ -n "$M" ] && [ "$Q" -lt "$M" ]; then ok "queue STOP precedes the merge"; else no "queue STOP precedes the merge"; fi
if grep -qF 'merge-on-finish:yes' "$F"; then ok "02-merge gates on merge-on-finish:yes"; else no "02-merge gates on merge-on-finish:yes"; fi
W=$(grep -n 'Without `merge-on-finish:yes`' "$F" | head -1 | cut -d: -f1)
if [ -n "$W" ] && [ -n "$M" ] && [ "$W" -lt "$M" ]; then ok "without-flag STOP precedes the merge"; else no "without-flag STOP precedes the merge"; fi
P3=$(grep -n 'Could not read the reviewed-head pin' "$F" | head -1 | cut -d: -f1)
P1=$(grep -n 'No reviewed-head pin recorded' "$F" | head -1 | cut -d: -f1); P2=$(grep -n 'differs from the reviewed head' "$F" | head -1 | cut -d: -f1)
if [ -n "$P1" ] && [ -n "$P2" ] && [ -n "$M" ] && [ "$P1" -lt "$M" ] && [ "$P2" -lt "$M" ]; then ok "pin STOPs precede the merge"; else no "pin STOPs precede the merge"; fi
if [ -n "$P3" ] && [ -n "$M" ] && [ "$P3" -lt "$M" ]; then ok "pin lookup-failure STOP precedes the merge"; else no "pin lookup-failure STOP precedes the merge"; fi
# N1-144: first DIRTY routes to resolve-dirty.md; BLOCKED/BEHIND and a second DIRTY keep the STOP.
D=$(grep -n 'references/resolve-dirty.md' "$F" | head -1 | cut -d: -f1)
if [ -n "$D" ] && [ -n "$M" ] && [ "$D" -lt "$M" ]; then ok "3.1 DIRTY points at resolve-dirty.md before the merge"; else no "3.1 DIRTY points at resolve-dirty.md before the merge"; fi
if grep -qF 'cannot merge yet' "$F" && grep -qF 'after a resolve attempt in this run' "$F"; then ok "BLOCKED/BEHIND and second DIRTY keep the STOP"; else no "BLOCKED/BEHIND and second DIRTY keep the STOP"; fi

# Nth bash block of a markdown file (default 02-merge.md), placeholders bound to env vars.
block() { awk -v n="$1" '/^ *```bash/{c++; if(c==n){b=1;next}} b&&/^ *```/{exit} b' "${2:-$F}" \
    | sed -e 's#^ *source ~/.n1/preamble.sh$#:#' -e 's/"<n>"/"${TN-7}"/' -e 's/"<head>"/"${TH-}"/' -e 's/"<mergeMethod>"/"${TMM-}"/' \
          -e 's/"<id>"/"${TID-N1-T}"/' -e 's/"<dev>"/"${TDEV-0}"/' -e 's/"<old>"/"${TOLD-}"/' -e 's/"<new>"/"${TNEW-}"/'; }
PRE=$(block 1); MRG=$(block 2)
if grep -qF 'gh pr checks' <<<"$PRE"; then ok "block 1 is the pre-check"; else no "block 1 is the pre-check"; fi
if grep -qF 'gh pr merge' <<<"$MRG"; then ok "block 2 is the merge"; else no "block 2 is the merge"; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
q=; p=; for a in "$@"; do if [ "$p" = --jq ] || [ "$p" = -q ]; then q=$a; fi; p=$a; done
DG='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"nodes":[]}}}}}'
case "$1 $2" in
  "pr checks") [ -z "${CHECKS_ERR:-}" ] || { echo "$CHECKS_ERR" >&2; exit 1; }; R=${CHECKS:-[]} ;;
  "repo view") [ -z "${REPO_FAIL:-}" ] || exit 1; R='{"nameWithOwner":"o/r"}' ;;
  "api graphql") [ -z "${GQL_ERR:-}" ] || exit 1; R=${GQL:-$DG} ;;
  "pr merge") echo "$*" >> "$LOG"; [ "${MERGE_EXIT:-0}" = 0 ] || { echo "merge blocked by branch protection" >&2; exit 1; }; exit 0 ;;
  "pr view") case "$*" in *headRefName*) R='{"headRefName":"feat","baseRefName":"main"}' ;; *headRefOid*) R="{\"headRefOid\":\"${HEADSHA:-}\",\"isDraft\":${DRAFT:-false},\"mergeStateStatus\":\"${MSS:-CLEAN}\"}" ;; *) R=${VIEW:-} ;; esac ;;
  *) exit 1 ;;
esac
if [ -n "$q" ]; then jq -r "$q" <<<"$R"; else echo "$R"; fi
EOF
chmod +x "$T/bin/gh"
S=0123456789abcdef0123456789abcdef01234567
O=fedcba9876543210fedcba9876543210fedcba98
export N1_HOME="$T/home" CFG="$ROOT/lib/config.sh"
PIN="$T/home/review-pins/o_r_7"; mkdir -p "${PIN%/*}"; echo "$S" > "$PIN"

pre() { OUT=$(cd "${WD:-$T}" && PATH="$T/bin:$PATH" HEADSHA=${HS-$S} bash -c 'source "$CFG"; '"$PRE" 2>&1); }
CHECKS='[{"bucket":"pass"},{"bucket":"skipping"}]' pre
has "pre: green CI" "checks:fail=0 pending=0"
has "pre: head sha printed" "head:$S"
has "pre: no unresolved threads" "threads:0"
line "pre: reviewed-head pin printed" "pin:$S"
rm -f "$PIN"; CHECKS='[]' pre
line "pre: missing pin prints an empty pin" "pin:"
REPO_FAIL=1 CHECKS='[]' pre
line "pre: pin lookup failure prints pin:unavailable" "pin:unavailable"
has "pre: no Codex receipt -> codex:none" "codex:none"
RC="$T/home/review-receipts/s1"; mkdir -p "$RC"
echo '{"outcome":"skipped"}' > "$RC/o_r_7.json"; pre
has "pre: skipped Codex receipt -> codex:not-ran" "codex:not-ran"
echo '{"outcome":"ran"}' > "$RC/o_r_7.json"; pre
has "pre: ran Codex receipt -> codex:ran" "codex:ran"
echo "$S" > "$PIN"
CHECKS='[{"bucket":"pass"},{"bucket":"fail"},{"bucket":"cancel"}]' pre
has "pre: failed and cancelled counted" "checks:fail=2 pending=0"
CHECKS='[{"bucket":"pending"}]' pre
has "pre: pending counted" "checks:fail=0 pending=1"
CHECKS_ERR="no checks reported on the 'me/T-1' branch" pre
has "pre: no CI -> checks:none" "checks:none"
CHECKS_ERR="HTTP 502" pre
has "pre: API error fails closed" "checks:error HTTP 502"
GQL='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"nodes":[{"isResolved":true},{"isResolved":false}]}}}}}' pre
has "pre: unresolved threads counted" "threads:1"
GQL_ERR=1 pre
has "pre: graphql error -> threads:error" "threads:error"
GQL='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":150,"nodes":[{"isResolved":true}]}}}}}' pre
has "pre: >100 threads -> threads:truncated" "threads:truncated"
DRAFT=true pre
has "pre: draft reported" "draft:true"
MSS=DIRTY pre
has "pre: dirty reported" "state:DIRTY"
MSS=BLOCKED pre
has "pre: blocked reported" "state:BLOCKED"
mkdir -p "$T/wf/.github/workflows" "$T/nowf"; echo "on: pull_request" > "$T/wf/.github/workflows/ci.yml"
mkdir -p "$T/pu/.github/workflows"; echo "on: push" > "$T/pu/.github/workflows/ci.yml"
for d in wf pu nowf; do git init -q "$T/$d"; done
CHECKS_ERR="no checks reported on the 'me/T-1' branch" WD="$T/wf" pre
has "pre: no checks + pull_request workflow -> checks:expected" "checks:expected"
CHECKS_ERR="no checks reported on the 'me/T-1' branch" WD="$T/pu/.github" pre
has "pre: push-only workflow -> checks:none" "checks:none"
CHECKS_ERR="no checks reported on the 'me/T-1' branch" WD="$T/nowf" pre
has "pre: no checks, no workflow -> checks:none" "checks:none"
TN='7;x' pre
has "pre: non-digit PR rejected" "pr:invalid"

mrg() { : > "$T/log"; OUT=$(PATH="$T/bin:$PATH" LOG="$T/log" TH="${TH-$S}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; '"$MRG" 2>&1); ARGS=$(cat "$T/log"); }
V="{\"state\":\"MERGED\",\"mergeCommit\":{\"oid\":\"$S\"}}"
VIEW=$V mrg
has "merge: announces method" "mergeOnFinish=true: merging PR #7 (squash)"
has "merge: state re-read" "state:MERGED sha:$S"
if [ "$ARGS" = "pr merge 7 --squash --match-head-commit $S" ]; then ok "merge: squash default, head pinned"; else no "merge args: $ARGS"; fi
TMM=rebase VIEW=$V mrg
if [ "$ARGS" = "pr merge 7 --rebase --match-head-commit $S" ]; then ok "merge: configured method used"; else no "merge args: $ARGS"; fi
TMM=fast VIEW=$V mrg
has "merge: invalid method rejected" "method:invalid"
if [ -z "$ARGS" ]; then ok "merge: invalid method never calls gh pr merge"; else no "merge: invalid method called gh: $ARGS"; fi
TH=abc VIEW=$V mrg
has "merge: bad head rejected" "head:invalid"
if [ -z "$ARGS" ]; then ok "merge: bad head never calls gh pr merge"; else no "merge: bad head called gh: $ARGS"; fi
MERGE_EXIT=1 VIEW='{"state":"OPEN","mergeCommit":null}' mrg
has "merge: gh error surfaced" "merge blocked by branch protection"
has "merge: failure leaves state OPEN" "state:OPEN sha:"
if [ "$(wc -l <"$T/log")" = 1 ]; then ok "merge: no retry"; else no "merge: retried"; fi

MERGE_EXIT=0 VIEW='{"state":"OPEN","mergeCommit":null}' mrg
has "merge: queued shows exit 0 with state OPEN" "merge-exit:0"
has "merge: queued state OPEN" "state:OPEN sha:"

echo "$O" > "$PIN"; VIEW=$V mrg
has "merge: head != pin refused" "pin:mismatch"
if [ -z "$ARGS" ]; then ok "merge: head != pin never calls gh pr merge"; else no "merge: head != pin called gh: $ARGS"; fi
rm -f "$PIN"; VIEW=$V mrg
has "merge: missing pin refused" "pin:mismatch"
if [ -z "$ARGS" ]; then ok "merge: missing pin never calls gh pr merge"; else no "merge: missing pin called gh: $ARGS"; fi
echo "$S" > "$PIN"

for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; VIEW=$V mrg; unset "${g%%=*}"
  has "merge: denied with $g" "merge:denied"
  if [ -z "$ARGS" ]; then ok "merge: $g never calls gh pr merge"; else no "merge: $g called gh: $ARGS"; fi
done

# N1-144: references/resolve-dirty.md against a temp bare origin + clone (hermetic git config).
RF=skills/n1-finish/references/resolve-dirty.md
if grep -qiF 'dispatch persona developer' "$RF"; then ok "resolve-dirty dispatches the developer persona"; else no "resolve-dirty dispatches the developer persona"; fi
RES=$(block 1 "$RF")
if grep -qF 'git rebase' <<<"$RES"; then ok "resolve block 1 is the rebase"; else no "resolve block 1 is the rebase"; fi
printf '[init]\n\tdefaultBranch = main\n' > "$T/gitconfig"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
G="$T/g"
setv() { jq -n --arg v "$1" '{name:"n1",version:$v}' > .claude-plugin/plugin.json; jq -n --arg v "$1" '{plugins:[{name:"n1",version:$v}]}' > .claude-plugin/marketplace.json; }
fx() { # <base-ver> <main-ver> <pr-ver>; SRC_PR / SRC_MAIN add conflicting src.txt commits. PR branch feat = reviewed head. PR version must differ from main's, else git sees identical changes and no manifest conflict arises. cp -p keeps bump-version.sh mode 100644 as in the real repo.
  rm -rf "$G"; mkdir -p "$G"; git init -q --bare "$G/o.git"; git init -q "$G/w"
  ( cd "$G/w" && mkdir -p .claude-plugin scripts && cp -p "$ROOT/scripts/bump-version.sh" scripts/ && setv "$1" && echo base > src.txt \
    && git add -A && git commit -qm base && git remote add origin "$G/o.git" && git push -q origin main \
    && git checkout -q -b feat && setv "$3" && git commit -qam "chore: bump version to $3 (N1-T)" \
    && { [ -z "${SRC_PR:-}" ] || { echo "$SRC_PR" > src.txt && git commit -qam "pr change"; }; } && git push -q origin feat \
    && git checkout -q main && setv "$2" && git commit -qam "main bump" \
    && { [ -z "${SRC_MAIN:-}" ] || { echo "$SRC_MAIN" > src.txt && git commit -qam "main change"; }; } && git push -q origin main \
    && git checkout -q feat ) || no "fixture $*"
  OH=$(git -C "$G/w" rev-parse HEAD); echo "$OH" > "$PIN"
}
gw() { git -C "$G/w" "$@"; }
res() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" TH="${TH-$OH}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; '"$RES" 2>&1); }
intact() { # branch at the reviewed head, no rebase, clean tree, origin and pin unchanged
  if [ "$(gw rev-parse HEAD)" = "$OH" ] && [ ! -d "$G/w/.git/rebase-merge" ] && [ -z "$(gw status --porcelain --untracked-files=no)" ] \
     && [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "$1"; else no "$1"; fi
}

# Version-only conflict: rebase, take main's manifests, one re-bump commit above main (minor class).
fx 5.10.0 5.12.0 5.11.0; res; NH=$(gw rev-parse HEAD)
line "resolve: manifest-only conflict re-bumped above main" "resolve:ready old=$OH new=$NH bumped=5.13.0"
if [ "$(gw log --format=%s origin/main..HEAD)" = "chore: bump version to 5.13.0 (N1-T)" ]; then ok "resolve: one bump commit on top of main"; else no "resolve: commits $(gw log --format=%s origin/main..HEAD | tr '\n' '|')"; fi
if [ "$(jq -r .version "$G/w/.claude-plugin/plugin.json") $(jq -r '.plugins[0].version' "$G/w/.claude-plugin/marketplace.json")" = "5.13.0 5.13.0" ]; then ok "resolve: both manifests at 5.13.0"; else no "resolve: both manifests at 5.13.0"; fi
if [ "$(gw diff --name-only origin/main HEAD | tr '\n' ' ')" = ".claude-plugin/marketplace.json .claude-plugin/plugin.json " ] && [ ! -d "$G/w/.git/rebase-merge" ]; then ok "resolve: only manifests differ from main, rebase finished"; else no "resolve: only manifests differ from main, rebase finished"; fi
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "resolve: nothing pushed, pin untouched"; else no "resolve: nothing pushed, pin untouched"; fi

# Bump class follows the PR's original delta (patch, major); last row: identical bump on both sides is not a git conflict (the PR commit is dropped) but is still re-bumped above main.
for c in "5.11.0 5.11.2 5.11.1 5.11.3" "5.11.0 5.12.0 6.0.0 6.0.0" "5.11.0 5.12.0 5.12.0 5.13.0"; do
  set -- $c; fx "$1" "$2" "$3"; res
  has "resolve: PR $3 (base $1) over main $2 -> $4" "bumped=$4"
done

# Non-manifest conflict: developer round, then the block finishes the rebase.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res
line "resolve: other conflict handed to the developer" "resolve:conflicts old=$OH files:src.txt"
if [ -d "$G/w/.git/rebase-merge" ]; then ok "resolve: rebase left in progress for the developer"; else no "resolve: rebase left in progress for the developer"; fi
res
has "resolve: a <dev>=0 call never touches an in-progress rebase" "resolve:skip rebase-in-progress"
echo merged > "$G/w/src.txt"; gw add src.txt
TDEV=1 res; NH=$(gw rev-parse HEAD)
line "resolve: developer round completes the rebase" "resolve:ready old=$OH new=$NH bumped=5.13.0"
if [ "$(cat "$G/w/src.txt")" = merged ] && gw merge-base --is-ancestor origin/main HEAD; then ok "resolve: developer resolution kept on top of main"; else no "resolve: developer resolution kept on top of main"; fi

# Escalation: every failure aborts the rebase, restores the reviewed head, pushes nothing.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; gw add src.txt; TDEV=1 res
has "resolve: conflict markers left by the developer abort" "resolve:abort markers"
intact "resolve: markers abort restores the reviewed head"
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; TDEV=1 res
has "resolve: file still unmerged after the developer round aborts" "resolve:abort conflicts files:src.txt"
intact "resolve: unmerged abort restores the reviewed head"
fx 5.11.0 5.12.0-rc.1 5.12.0; res
has "resolve: non-X.Y.Z version aborts" "resolve:abort version"
intact "resolve: version abort changes nothing"

# Gating and preconditions: no git writes.
fx 5.10.0 5.12.0 5.11.0
for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; res; unset "${g%%=*}"
  has "resolve: denied with $g" "resolve:denied"
  intact "resolve: $g changes nothing"
done
gw checkout -q main; res; gw checkout -q feat
has "resolve: wrong branch skipped" "resolve:skip branch"
echo x >> "$G/w/src.txt"; res; gw checkout -q -- src.txt
has "resolve: uncommitted changes skipped" "resolve:skip dirty"
echo "$S" > "$PIN"; res
has "resolve: pin not at the reviewed head skipped" "resolve:skip pin"
TH=$S res
has "resolve: local tip not at the reviewed head skipped" "resolve:skip local-tip"
echo "$OH" > "$PIN"; intact "resolve: skips change nothing"
# N1-144 § Push: pinned lease, pin advanced only for the pushed rebased head.
PSH=$(block 2 "$RF"); CI=$(block 3 "$RF")
if grep -qF -- '--force-with-lease=' <<<"$PSH" && ! grep -qE -- '--force( |$)|push -f' "$RF"; then ok "resolve push uses a pinned lease, never a bare force"; else no "resolve push uses a pinned lease, never a bare force"; fi
psh() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; '"$PSH" 2>&1); }
fx 5.10.0 5.12.0 5.11.0; res; NH=$(gw rev-parse HEAD)
for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; TOLD=$OH TNEW=$NH psh; unset "${g%%=*}"
  has "push: denied with $g" "resolve:denied"
done
echo "$S" > "$PIN"; TOLD=$OH TNEW=$NH psh; echo "$OH" > "$PIN"
has "push: pin moved since resolve refused" "pin:moved"
TOLD=$OH TNEW=$S psh
has "push: local tip != new refused" "push:skip"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "push: refusals push nothing"; else no "push: refusals push nothing"; fi
TOLD=$OH TNEW=$NH psh
has "push: pin advanced to the rebased head" "pin:advanced ${NH:0:7}"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$NH" ] && [ "$(cat "$PIN")" = "$NH" ]; then ok "push: origin and pin at the rebased head"; else no "push: origin and pin at the rebased head"; fi
# 3.1 re-check after the push: pin == new head; the session-keyed Codex receipt is unaffected.
HS=$NH pre
line "pre: re-check after resolve sees pin == new head" "pin:$NH"
has "pre: re-check head is the rebased head" "head:$NH"
has "pre: Codex receipt survives the resolve push" "codex:ran"

fx 5.10.0 5.12.0 5.11.0; res; NH=$(gw rev-parse HEAD)
git clone -q "$G/o.git" "$G/x" && git -C "$G/x" checkout -q feat && echo other > "$G/x/other.txt" \
  && git -C "$G/x" add other.txt && git -C "$G/x" commit -qm other && git -C "$G/x" push -q origin feat
RFH=$(git -C "$G/o.git" rev-parse feat)
TOLD=$OH TNEW=$NH psh
has "push: lease rejects a remote moved since review" "push:rejected"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$RFH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "push: rejected push leaves origin and pin"; else no "push: rejected push leaves origin and pin"; fi

# N1-144 § CI wait: sequenced fake gh (one line per poll: <checks-json|ERR:msg>|<mergeStateStatus>).
mkdir -p "$T/cibin"
cat > "$T/cibin/gh" <<'EOF'
#!/usr/bin/env bash
q=; p=; for a in "$@"; do if [ "$p" = --jq ] || [ "$p" = -q ]; then q=$a; fi; p=$a; done
n=$(cat "$CIN" 2>/dev/null || echo 0)
[ "$1 $2" != "pr checks" ] || { n=$((n+1)); echo "$n" > "$CIN"; }
L=$(sed -n "${n}p" "$CIS"); [ -n "$L" ] || L=$(tail -n1 "$CIS")
case "$1 $2" in
  "pr checks") R=${L%%|*}; case "$R" in ERR:*) echo "${R#ERR:}" >&2; exit 1;; esac ;;
  "pr view") R="{\"mergeStateStatus\":\"${L##*|}\"}" ;;
  *) exit 1 ;;
esac
jq -r "$q" <<<"$R"
EOF
chmod +x "$T/cibin/gh"
ci() { printf '%s\n' "$@" > "$T/cis"; rm -f "$T/cin"; OUT=$(cd "${WD:-$T/wf}" && PATH="$T/cibin:$PATH" CIS="$T/cis" CIN="$T/cin" RESOLVE_CI_POLLS="${POLLS:-3}" RESOLVE_CI_SLEEP=0 bash -c "$CI" 2>&1); }
PS='[{"bucket":"pass"}]'
ci '[{"bucket":"pending"}]|BLOCKED' "$PS|CLEAN"
line "ci: pending then pass" "ci:pass"
line "ci: merge state read" "state:CLEAN"
ci '[{"bucket":"pass"},{"bucket":"fail"}]|BLOCKED'
line "ci: failure stops the wait" "ci:fail"
ci '[{"bucket":"pending"}]|BLOCKED'
line "ci: stuck pending times out" "ci:timeout"
ci "$PS|UNKNOWN" "$PS|CLEAN"
line "ci: UNKNOWN merge state waited out" "state:CLEAN"
ci "$PS|UNKNOWN"
line "ci: green checks with UNKNOWN to the end continue" "ci:pass"
POLLS=1 ci "ERR:no checks reported on the 'feat' branch|CLEAN"
line "ci: no checks + pull_request workflow counts as pending" "ci:timeout"
POLLS=1 WD="$T/nowf" ci "ERR:no checks reported on the 'feat' branch|CLEAN"
line "ci: no checks, no workflow passes" "ci:pass"
exit $FAIL
