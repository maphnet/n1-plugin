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
# N1-144/N1-151: first DIRTY or BEHIND routes to resolve-dirty.md; BLOCKED and a second DIRTY/BEHIND keep the STOP.
D=$(grep -n 'references/resolve-dirty.md' "$F" | head -1 | cut -d: -f1)
if [ -n "$D" ] && [ -n "$M" ] && [ "$D" -lt "$M" ]; then ok "3.1 DIRTY points at resolve-dirty.md before the merge"; else no "3.1 DIRTY points at resolve-dirty.md before the merge"; fi
if grep -qF 'cannot merge yet' "$F" && grep -qF 'after a resolve attempt in this run' "$F"; then ok "BLOCKED and second DIRTY/BEHIND keep the STOP"; else no "BLOCKED and second DIRTY/BEHIND keep the STOP"; fi
if grep -qF '`state:DIRTY` or `state:BEHIND` (first in this run)' "$F"; then ok "3.1: first BEHIND routes to resolve-dirty"; else no "3.1: first BEHIND routes to resolve-dirty"; fi
if grep -qF '`state:BLOCKED` / `BEHIND`' "$F"; then no "3.1: BEHIND is not an unconditional STOP"; else ok "3.1: BEHIND is not an unconditional STOP"; fi
if grep -qF 'a second `state:DIRTY` or `state:BEHIND` is a **STOP**' skills/n1-finish/references/resolve-dirty.md; then ok "resolve-dirty: second DIRTY/BEHIND stops"; else no "resolve-dirty: second DIRTY/BEHIND stops"; fi
# N1-151 pinless: the pin line precedes DIRTY/BEHIND, routes to § Re-pin interactively, escalates unattended, no merge-by-hand.
PE=$(grep -n 'No reviewed-head pin recorded' "$F" | head -1 | cut -d: -f1); DB=$(grep -n '`state:DIRTY` or `state:BEHIND` (first in this run)' "$F" | head -1 | cut -d: -f1)
if [ -n "$PE" ] && [ -n "$DB" ] && [ "$PE" -lt "$DB" ]; then ok "3.1: pinless line precedes DIRTY/BEHIND"; else no "3.1: pinless line precedes DIRTY/BEHIND"; fi
PL=$(sed -n "${PE:-1}p" "$F")
if grep -qF '§ Re-pin' <<<"$PL" && grep -qF 'N1 does not pin unattended' <<<"$PL" && grep -qF 'every **STOP** in 3.1 and 3.4 (and in resolve-dirty.md) is also added under `## Escalations` and posted as a `N1 [headless]`' "$F"; then ok "3.1: pinless routes to § Re-pin, escalates unattended"; else no "3.1: pinless routes to § Re-pin, escalates unattended"; fi
if grep -qF 'Merge it yourself' <<<"$PL"; then no "3.1: pinless has no merge-by-hand dead end"; else ok "3.1: pinless has no merge-by-hand dead end"; fi
# N1-157: a failed 3.4 merge with a DIRTY/BEHIND re-read resolves once (shared attempt with 3.1); a second conflict and every other failure STOP.
R34=$(grep -n '`mss:DIRTY` or `mss:BEHIND` and no resolve attempt yet in this run' "$F" | head -1 | cut -d: -f1)
if [ -n "$R34" ] && [ -n "$M" ] && [ "$R34" -gt "$M" ] && grep -qF 'references/resolve-dirty.md' <<<"$(sed -n "${R34}p" "$F")"; then ok "3.4: first conflict routes to resolve-dirty"; else no "3.4: first conflict routes to resolve-dirty"; fi
if grep -qF '`mss:DIRTY` or `mss:BEHIND` after a resolve attempt in this run' "$F" && grep -qF 'has conflicts again after conflict resolution' "$F"; then ok "3.4: second conflict STOPs"; else no "3.4: second conflict STOPs"; fi
if grep -qF 'Any other `state:` or `mss:`' "$F" && grep -qF 'Never retry and never fall back to auto-merge' "$F"; then ok "3.4: non-conflict failures STOP without retry"; else no "3.4: non-conflict failures STOP without retry"; fi
if grep -qF 'no retry except the single resolve-then-retry below' "$F"; then ok "3.4: header names the single retry"; else no "3.4: header names the single retry"; fi
if grep -qF 'after a resolve attempt in this run (from this list or from 3.4)' "$F"; then ok "3.1: a 3.4 resolve attempt counts"; else no "3.1: a 3.4 resolve attempt counts"; fi
RD=skills/n1-finish/references/resolve-dirty.md
if grep -qF 'or from § 3.4 after a failed merge whose re-read is `mss:DIRTY` or `mss:BEHIND`' "$RD" && grep -qF 'One attempt per run, shared by 3.1 and 3.4.' "$RD"; then ok "resolve-dirty: reachable from 3.4, one shared attempt"; else no "resolve-dirty: reachable from 3.4, one shared attempt"; fi

# Nth bash block of a markdown file (default 02-merge.md), placeholders bound to env vars.
block() { awk -v n="$1" '/^ *```bash/{c++; if(c==n){b=1;next}} b&&/^ *```/{exit} b' "${2:-$F}" \
    | sed -e 's#^ *source ~/.n1/preamble.sh$#:#' -e 's/"<n>"/"${TN-7}"/' -e 's/"<head>"/"${TH-}"/' -e 's/"<mergeMethod>"/"${TMM-}"/' \
          -e 's/"<id>"/"${TID-N1-T}"/' -e 's/"<dev>"/"${TDEV-0}"/' -e 's/"<stop>"/"${TSTOP-}"/' -e 's/"<snap>"/"${TSNAP-$SN}"/' -e 's/"<old>"/"${TOLD-}"/' -e 's/"<new>"/"${TNEW-}"/'; }
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
  "pr merge") echo "$*" >> "$LOG"; [ "${MERGE_EXIT:-0}" = 0 ] || { echo "${MERGE_ERR:-merge blocked by branch protection}" >&2; exit 1; }; exit 0 ;;
  "pr view") case "$*" in *headRefName*) R="{\"headRefName\":\"${HEADREF:-feat}\",\"baseRefName\":\"${BASEREF:-main}\",\"isCrossRepository\":${XREPO:-false}}" ;; *headRefOid*) R="{\"headRefOid\":\"${HEADSHA:-}\",\"isDraft\":${DRAFT:-false},\"mergeStateStatus\":\"${MSS:-CLEAN}\"}" ;;
      *mergeStateStatus*) [ -z "${MSS_FAIL:-}" ] || exit 1; v=${MSS:-CLEAN}; if [ -s "${MSSQ:-}" ]; then v=$(head -n1 "$MSSQ"); [ "$(wc -l <"$MSSQ")" -le 1 ] || { tail -n +2 "$MSSQ" > "$MSSQ.t" && mv "$MSSQ.t" "$MSSQ"; }; fi; R="{\"mergeStateStatus\":\"$v\"}" ;;
      *) R=${VIEW:-} ;; esac ;;
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

mrg() { : > "$T/log"; OUT=$(PATH="$T/bin:$PATH" LOG="$T/log" TH="${TH-$S}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; n1_fullauto_enabled() { echo "${FA_KEY-false}"; }; '"$MRG" 2>&1); ARGS=$(cat "$T/log"); }
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
# N1-157: a failed merge re-reads mergeStateStatus (polling past UNKNOWN); a successful one does not.
OPENV='{"state":"OPEN","mergeCommit":null}'
MERGE_REREAD_SLEEP=0 MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: CLEAN for the whole budget is reported as CLEAN" "mss:CLEAN"
printf 'CLEAN\nCLEAN\nDIRTY\n' > "$T/mssq"
MSSQ="$T/mssq" MERGE_REREAD_SLEEP=0 MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: re-read polls past a stale CLEAN" "mss:DIRTY"
MSS_FAIL=1 MERGE_REREAD_SLEEP=0 MERGE_EXIT=1 VIEW=$OPENV mrg
if grep -qx 'mss:' <<<"$OUT"; then ok "merge: failed re-read prints an empty mss"; else no "merge: failed re-read prints an empty mss"; fi
MERGE_REREAD_POLLS=0 MERGE_EXIT=1 VIEW=$OPENV mrg
if grep -qx 'mss:' <<<"$OUT"; then ok "merge: zero polls prints an empty mss"; else no "merge: zero polls prints an empty mss"; fi
printf 'DIRTY\n' > "$T/mssq"
MSSQ="$T/mssq" MERGE_EXIT=1 MERGE_ERR="Pull Request has merge conflicts" VIEW=$OPENV mrg
has "merge: conflict error surfaced" "Pull Request has merge conflicts"
line "merge: conflict re-read is DIRTY" "mss:DIRTY"
if [ "$(wc -l <"$T/log")" = 1 ]; then ok "merge: conflict does not retry inside the block"; else no "merge: conflict retried inside the block"; fi
printf 'UNKNOWN\nUNKNOWN\nDIRTY\n' > "$T/mssq"
MSSQ="$T/mssq" MERGE_REREAD_SLEEP=0 MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: re-read polls past UNKNOWN" "mss:DIRTY"
printf 'UNKNOWN\n' > "$T/mssq"
MSSQ="$T/mssq" MERGE_REREAD_POLLS=2 MERGE_REREAD_SLEEP=0 MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: UNKNOWN to the end is reported as UNKNOWN" "mss:UNKNOWN"
MSS=BEHIND MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: BEHIND re-read reported" "mss:BEHIND"
MSS=BLOCKED MERGE_EXIT=1 VIEW=$OPENV mrg
line "merge: branch-protection failure re-reads BLOCKED" "mss:BLOCKED"
VIEW=$V mrg
if grep -q '^mss:' <<<"$OUT"; then no "merge: success skips the re-read"; else ok "merge: success skips the re-read"; fi
rm -f "$T/mssq"
# N1-146: the guard is the shared predicate; queue/headless merge only with fullAuto too.
if grep -qF '[ "$(n1_merge_authorized)" = true ] || { echo merge:denied; exit 1; }' <<<"$MRG"; then ok "merge: guard is n1_merge_authorized"; else no "merge: guard is n1_merge_authorized"; fi
N1_QUEUE_RUN_ID=q-1 N1_HEADLESS=1 VIEW=$V mrg
has "merge: queue without fullAuto denied" "merge:denied"
if [ -z "$ARGS" ]; then ok "merge: queue without fullAuto never calls gh pr merge"; else no "merge: queue denied called gh: $ARGS"; fi
N1_QUEUE_RUN_ID=q-1 N1_HEADLESS=1 FA_KEY=true VIEW=$V mrg
has "merge: queue + fullAuto + mergeOnFinish merges" "state:MERGED sha:$S"
if grep -qF 'Run /n1:n1-finish <ID> to merge locally.' "$F"; then ok "2b: chained gate message"; else no "2b: chained gate message"; fi
if grep -qF 'N1 [headless]' "$F"; then ok "threads: headless STOP posts a tracker comment"; else no "threads: headless STOP posts a tracker comment"; fi

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
  ( cd "$G/w" && mkdir -p .claude-plugin scripts && cp -p "$ROOT/scripts/bump-version.sh" scripts/ && setv "$1" && echo base > src.txt && echo keep > keep.txt \
    && git add -A && git commit -qm base && git remote add origin "$G/o.git" && git push -q origin main \
    && git checkout -q -b feat && setv "$3" && git commit -qam "chore: bump version to $3 (N1-T)" \
    && { [ -z "${SRC_PR:-}" ] || { echo "$SRC_PR" > src.txt && { [ -z "${PR_SIDE:-}" ] || echo keep > side.txt; } && git add -A && git commit -qm "pr change"; }; } && git push -q origin feat \
    && git checkout -q main && setv "$2" && git commit -qam "main bump" \
    && { [ -z "${SRC_MAIN:-}" ] || { echo "$SRC_MAIN" > src.txt && git commit -qam "main change"; }; } && git push -q origin main \
    && git checkout -q feat ) || no "fixture $*"
  OH=$(git -C "$G/w" rev-parse HEAD); echo "$OH" > "$PIN"; SN=
}
gw() { git -C "$G/w" "$@"; }
res() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" TH="${TH-$OH}" TSNAP="${TSNAP-$SN}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; n1_fullauto_enabled() { echo "${FA_KEY-false}"; }; '"$RES" 2>&1); s=$(sed -n 's/.* snap=\([0-9a-f]*\) .*/\1/p' <<<"$OUT"); [ -z "$s" ] || SN=$s; }
intact() { # branch at the reviewed head, no rebase, clean tree, origin and pin unchanged
  if [ "$(gw rev-parse HEAD)" = "$OH" ] && [ ! -d "$G/w/.git/rebase-merge" ] && [ -z "$(gw status --porcelain --untracked-files=no)" ] \
     && [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "$1"; else no "$1"; fi
}

# Version-only conflict: rebase, take main's manifests, one re-bump commit above main (minor class).
fx 5.10.0 5.12.0 5.11.0; res; NH=$(gw rev-parse HEAD)
line "resolve: manifest-only conflict re-bumped above main" "resolve:ready old=$OH new=$NH bumped=5.13.0"
# N1-151: unattended DIRTY routes to resolve-dirty; its writing blocks guard on n1_merge_authorized alone.
if grep -qF 'Queue and headless runs follow it too' "$F"; then ok "3.1: unattended DIRTY routes to resolve-dirty"; else no "3.1: unattended DIRTY routes to resolve-dirty"; fi
if [ "$(grep -cF '[ "$(n1_merge_authorized)" = true ] || { echo resolve:denied; exit 1; }' "$RF")" = 2 ]; then ok "resolve-dirty: both writing blocks guard on n1_merge_authorized"; else no "resolve-dirty: both writing blocks guard on n1_merge_authorized"; fi
if grep -qF 'N1 [headless]' "$RF"; then ok "resolve-dirty: unattended STOPs post a tracker comment"; else no "resolve-dirty: unattended STOPs post a tracker comment"; fi
if [ "$(gw log --format=%s origin/main..HEAD)" = "chore: bump version to 5.13.0 (N1-T)" ]; then ok "resolve: one bump commit on top of main"; else no "resolve: commits $(gw log --format=%s origin/main..HEAD | tr '\n' '|')"; fi
if [ "$(jq -r .version "$G/w/.claude-plugin/plugin.json") $(jq -r '.plugins[0].version' "$G/w/.claude-plugin/marketplace.json")" = "5.13.0 5.13.0" ]; then ok "resolve: both manifests at 5.13.0"; else no "resolve: both manifests at 5.13.0"; fi
if [ "$(gw diff --name-only origin/main HEAD | tr '\n' ' ')" = ".claude-plugin/marketplace.json .claude-plugin/plugin.json " ] && [ ! -d "$G/w/.git/rebase-merge" ]; then ok "resolve: only manifests differ from main, rebase finished"; else no "resolve: only manifests differ from main, rebase finished"; fi
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ "$(cat "$PIN")" = "$OH" ]; then ok "resolve: nothing pushed, pin untouched"; else no "resolve: nothing pushed, pin untouched"; fi
# N1-151: queue/headless runs resolve when n1_merge_authorized holds (fullAuto + mergeOnFinish); without fullAuto they stay denied.
for e in "N1_QUEUE_RUN_ID=q-1" "N1_HEADLESS=1"; do
  fx 5.10.0 5.12.0 5.11.0
  export "$e"; FA_KEY=false res; unset "${e%%=*}"
  line "resolve: denied for $e without fullAuto" "resolve:denied"
  intact "resolve: $e without fullAuto changes nothing"
  export "$e"; FA_KEY=true res; unset "${e%%=*}"; NH=$(gw rev-parse HEAD)
  line "resolve: $e + fullAuto re-bumps the manifest conflict" "resolve:ready old=$OH new=$NH bumped=5.13.0"
done
# Non-manifest conflict unattended: developer round, then the rebase completes (accept-as-is policy).
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0
N1_HEADLESS=1 FA_KEY=true res; ST=$(gw rev-parse HEAD)
line "resolve: headless conflict handed to the developer" "resolve:conflicts old=$OH stop=$ST snap=$SN files:src.txt"
# N1-151 BEHIND: base gained a non-conflicting commit; clean rebase, no re-bump while the PR version is above base.
bfx() { fx 5.10.0 5.12.0 5.11.0
  ( cd "$G/w" && git checkout -q main && git reset -q --hard HEAD~1 && echo o > other.txt && git add other.txt && git commit -qm "main other" && git push -q -f origin main && git checkout -q feat ) || no "behind fixture"; }
bfx; res; NH=$(gw rev-parse HEAD)
line "resolve: BEHIND PR rebased without a re-bump" "resolve:ready old=$OH new=$NH bumped=none"
if gw merge-base --is-ancestor origin/main HEAD && [ "$(gw log --format=%s origin/main..HEAD | tr '\n' '|')" = "chore: bump version to 5.11.0 (N1-T)|" ]; then ok "resolve: BEHIND keeps the PR commits on top of base"; else no "resolve: BEHIND keeps the PR commits on top of base"; fi
echo "$NH" > "$PIN"; TH=$NH res; echo "$OH" > "$PIN"
has "resolve: already on top of base skipped" "resolve:skip up-to-date"
bfx; N1_QUEUE_RUN_ID=q-1 FA_KEY=true res; NH=$(gw rev-parse HEAD)
line "resolve: queue BEHIND + fullAuto rebased" "resolve:ready old=$OH new=$NH bumped=none"
# N1-157 AC: stale CLEAN at 3.1 -> merge conflict at 3.4 -> resolve-dirty -> one merge retry at the new pin.
fx 5.10.0 5.12.0 5.11.0
MSS=CLEAN HS=$OH pre
has "stale: 3.1 reads a stale CLEAN" "state:CLEAN"
printf 'DIRTY\n' > "$T/mssq"
TH=$OH MSSQ="$T/mssq" MERGE_EXIT=1 MERGE_ERR="Pull Request has merge conflicts" VIEW='{"state":"OPEN","mergeCommit":null}' mrg
has "stale: merge conflict reported" "Pull Request has merge conflicts"
line "stale: failed merge re-reads DIRTY" "mss:DIRTY"
res; NH=$(gw rev-parse HEAD)
line "stale: resolve-dirty re-bumps the manifest conflict" "resolve:ready old=$OH new=$NH bumped=5.13.0"
echo "$NH" > "$PIN" # resolve-dirty § Push advances the pin (not exercised here)
TH=$NH VIEW=$V mrg
has "stale: retried merge lands" "state:MERGED sha:$S"
if [ "$ARGS" = "pr merge 7 --squash --match-head-commit $NH" ]; then ok "stale: retry pinned to the resolved head"; else no "stale: retry args: $ARGS"; fi
if grep -q '^mss:' <<<"$OUT"; then no "stale: successful retry skips the re-read"; else ok "stale: successful retry skips the re-read"; fi
rm -f "$T/mssq"; echo "$OH" > "$PIN"

# Bump class follows the PR's original delta (patch, major); last row: identical bump on both sides is not a git conflict (the PR commit is dropped) but is still re-bumped above main.
for c in "5.11.0 5.11.2 5.11.1 5.11.3" "5.11.0 5.12.0 6.0.0 6.0.0" "5.11.0 5.12.0 5.12.0 5.13.0"; do
  set -- $c; fx "$1" "$2" "$3"; res
  has "resolve: PR $3 (base $1) over main $2 -> $4" "bumped=$4"
done

# Non-manifest conflict: developer round, then the block finishes the rebase.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res
ST=$(gw rev-parse HEAD)
line "resolve: other conflict handed to the developer" "resolve:conflicts old=$OH stop=$ST snap=$SN files:src.txt"
if [ -d "$G/w/.git/rebase-merge" ]; then ok "resolve: rebase left in progress for the developer"; else no "resolve: rebase left in progress for the developer"; fi
res
has "resolve: a <dev>=0 call never touches an in-progress rebase" "resolve:skip rebase-in-progress"
echo merged > "$G/w/src.txt"; gw add src.txt
TDEV=1 TSTOP=$ST res; NH=$(gw rev-parse HEAD)
line "resolve: developer round completes the rebase" "resolve:ready old=$OH new=$NH bumped=5.13.0"
if [ "$(cat "$G/w/src.txt")" = merged ] && gw merge-base --is-ancestor origin/main HEAD; then ok "resolve: developer resolution kept on top of main"; else no "resolve: developer resolution kept on top of main"; fi

# Escalation: every failure aborts the rebase, restores the reviewed head, pushes nothing.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD); gw add src.txt; TDEV=1 TSTOP=$ST res
has "resolve: conflict markers left by the developer abort" "resolve:abort markers"
intact "resolve: markers abort restores the reviewed head"
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD); TDEV=1 TSTOP=$ST res
has "resolve: file still unmerged after the developer round aborts" "resolve:abort conflicts files:src.txt"
intact "resolve: unmerged abort restores the reviewed head"
# Developer commits during the rebase are refused; staged markers are caught after the rebase finishes (whole range).
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD)
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> pr\n' > "$G/w/src.txt"; gw add src.txt; gw commit -qm dev
TDEV=1 TSTOP=$ST res
has "resolve: developer commit rejected (scope)" "resolve:abort scope"
intact "resolve: developer commit restores the reviewed head"
# SEC-11: color.ui=always must not blind the marker scan.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD); gw config color.ui always
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> pr\n' > "$G/w/src.txt"; gw add src.txt
TDEV=1 TSTOP=$ST res
has "resolve: markers caught with color.ui=always" "resolve:abort markers"
intact "resolve: color.ui=always markers abort restores the reviewed head"
# SEC-1: files outside the conflict set; CR-1: a skip on the <dev>=1 call aborts the rebase.
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD)
echo merged > "$G/w/src.txt"; echo extra > "$G/w/extra.txt"; gw add src.txt extra.txt
TDEV=1 TSTOP=$ST res
has "resolve: out-of-scope file aborts" "resolve:abort scope"
intact "resolve: out-of-scope abort restores the reviewed head"
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; res; ST=$(gw rev-parse HEAD)
echo merged > "$G/w/src.txt"; gw add src.txt; echo "$S" > "$PIN"
TDEV=1 TSTOP=$ST res; echo "$OH" > "$PIN"
has "resolve: <dev>=1 pin skip" "resolve:skip pin"
intact "resolve: <dev>=1 skip aborts the rebase"
# N1-144 cycle 2: one invariant (snap= hash + HEAD == stop); each case aborts and restores the reviewed head.
stopfx() { res; ST=$(gw rev-parse HEAD); }
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; stopfx
echo merged > "$G/w/src.txt"; gw add src.txt; echo "exec true" >> "$G/w/.git/rebase-merge/git-rebase-todo"
TDEV=1 TSTOP=$ST res
has "resolve: rebase todo edit aborts" "resolve:abort scope"
intact "resolve: todo edit restores the reviewed head"
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; stopfx
cp "$G/w/keep.txt" "$G/w/src.txt"; gw add src.txt; gw rm -q keep.txt
TDEV=1 TSTOP=$ST res
has "resolve: staged deletion of an out-of-scope file aborts" "resolve:abort scope"
intact "resolve: staged deletion restores the reviewed head"
# N1-148: a real staged rename (name-only diffs would miss it); git must report R, not D+A.
PR_SIDE=1 SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; stopfx
echo merged > "$G/w/src.txt"; gw add src.txt; gw mv -f keep.txt side.txt
if grep -q '^R  keep.txt -> side.txt' <<< "$(gw status --porcelain)"; then ok "resolve: fixture stages a real rename"; else no "resolve: fixture stages a real rename"; fi
TDEV=1 TSTOP=$ST res
has "resolve: staged rename of an out-of-scope file aborts" "resolve:abort scope"
intact "resolve: staged rename restores the reviewed head"
PR_SIDE=1 SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; stopfx
echo merged > "$G/w/src.txt"; echo evil > "$G/w/side.txt"; gw add src.txt side.txt
TDEV=1 TSTOP=$ST res
has "resolve: edit to a non-conflict file of the picked commit aborts" "resolve:abort scope"
intact "resolve: non-conflict edit restores the reviewed head"
SRC_PR=pr SRC_MAIN=main fx 5.10.0 5.12.0 5.11.0; stopfx
echo 'src.txt -diff' > "$G/w/.git/info/attributes"
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> pr\n' > "$G/w/src.txt"; gw add src.txt
TDEV=1 TSTOP=$ST res
has "resolve: markers behind a -diff attribute are caught" "resolve:abort markers"
intact "resolve: attribute-hidden markers restore the reviewed head"
rm -f "$G/w/.git/info/attributes"
# CR-3: a PR that changed more than the version in a manifest goes to the developer.
SRC_PR=pr fx 5.10.0 5.12.0 5.11.0
( cd "$G/w" && jq '.keywords=["k"]' .claude-plugin/plugin.json > p.tmp && mv p.tmp .claude-plugin/plugin.json && git commit -qam "pr keywords" && git push -q origin feat ); OH=$(gw rev-parse HEAD); echo "$OH" > "$PIN"
res
has "resolve: PR manifest edit beyond the version goes to the developer" "resolve:conflicts"
gw rebase --abort >/dev/null 2>&1
# SEC-4: leading-zero version components abort instead of mis-bumping.
fx 5.10.0 5.08.0 5.11.0; res
has "resolve: leading-zero version aborts" "resolve:abort version"
# SEC-3: fork PR or head == base.
fx 5.10.0 5.12.0 5.11.0; XREPO=true res
has "resolve: fork PR skipped" "resolve:skip fork"
HEADREF=main res
has "resolve: head == base skipped" "resolve:skip fork"
BASEREF=-x res
has "resolve: option-like base skipped" "resolve:skip base"
intact "resolve: fork/base skips change nothing"
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
# Codex review: merge commits would be dropped by a plain rebase; ignored/untracked local files would be clobbered.
fx 5.10.0 5.12.0 5.11.0; gw checkout -q -b side main~1 && echo s > "$G/w/s.txt" && gw add -A && gw commit -qm side && gw checkout -q feat && gw merge -q --no-ff -m merge side; OH=$(gw rev-parse HEAD); echo "$OH" > "$PIN"; git -C "$G/w" push -q origin feat; res
has "resolve: merge commit in PR history skipped" "resolve:skip merges"
intact "resolve: merges skip changes nothing"
fx 5.10.0 5.12.0 5.11.0; echo keep.txt > "$G/w/.gitignore"; git -C "$G/w" add .gitignore; git -C "$G/w" commit -qm ign; OH=$(gw rev-parse HEAD); echo "$OH" > "$PIN"; git -C "$G/w" push -q origin feat
git -C "$G/w" rm -q --cached keep.txt; git -C "$G/w" commit -qm untrack; OH=$(gw rev-parse HEAD); echo "$OH" > "$PIN"; git -C "$G/w" push -q origin feat; echo mine > "$G/w/keep.txt"; res
has "resolve: ignored file tracked on the base skipped" "resolve:skip local-files"
if [ "$(cat "$G/w/keep.txt")" = mine ]; then ok "resolve: ignored local file preserved"; else no "resolve: ignored local file preserved"; fi
intact "resolve: local-files skip changes nothing"
fx 5.10.0 5.12.0 5.11.0; echo u > "$G/w/untracked.txt"; res
has "resolve: untracked file skipped" "resolve:skip local-files"
# N1-144 § Push: pinned lease, pin advanced only for the pushed rebased head.
PSH=$(block 2 "$RF"); CI=$(block 3 "$RF")
if grep -qF -- '--force-with-lease=' <<<"$PSH" && ! grep -qE -- '--force( |$)|push -f' "$RF"; then ok "resolve push uses a pinned lease, never a bare force"; else no "resolve push uses a pinned lease, never a bare force"; fi
psh() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; n1_fullauto_enabled() { echo "${FA_KEY-false}"; }; '"$PSH" 2>&1); }
fx 5.10.0 5.12.0 5.11.0; res; NH=$(gw rev-parse HEAD)
for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; TOLD=$OH TNEW=$NH psh; unset "${g%%=*}"
  has "push: denied with $g" "resolve:denied"
done
echo "$S" > "$PIN"; TOLD=$OH TNEW=$NH psh; echo "$OH" > "$PIN"
has "push: pin moved since resolve refused" "pin:moved"
TOLD=$OH TNEW=$S psh
has "push: local tip != new refused" "push:skip"
XREPO=true TOLD=$OH TNEW=$NH psh
has "push: fork PR refused" "push:skip"
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
# Non-lease failure (pre-receive hook declines; lease matches the remote tip) reports push:failed, not push:rejected.
printf '#!/bin/sh\necho hook-says-no >&2\nexit 1\n' > "$G/o.git/hooks/pre-receive"; chmod +x "$G/o.git/hooks/pre-receive"
echo "$RFH" > "$PIN"; TOLD=$RFH TNEW=$NH psh; rm -f "$G/o.git/hooks/pre-receive"
has "push: hook decline reports push:failed" "push:failed"
has "push: hook decline shows the git error" "hook-says-no"
if grep -qF "push:rejected" <<<"$OUT"; then no "push: hook decline is not push:rejected"; else ok "push: hook decline is not push:rejected"; fi
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$RFH" ] && [ "$(cat "$PIN")" = "$RFH" ]; then ok "push: failed push leaves origin and pin"; else no "push: failed push leaves origin and pin"; fi

# N1-151: an unattended push with fullAuto + mergeOnFinish pushes and advances the pin.
fx 5.10.0 5.12.0 5.11.0; N1_HEADLESS=1 FA_KEY=true res; NH=$(gw rev-parse HEAD)
N1_HEADLESS=1 FA_KEY=true TOLD=$OH TNEW=$NH psh
has "push: headless + fullAuto pushes" "pushed:${NH:0:7}"
has "push: headless + fullAuto advances the pin" "pin:advanced ${NH:0:7}"
# N1-151 § Re-pin (block 4): pin a pinless PR at its head only when local tip == remote head; interactive only; never overwrites.
RP=$(block 4 "$RF")
if grep -qF 'n1_review_pin set' <<<"$RP"; then ok "resolve block 4 is the re-pin"; else no "resolve block 4 is the re-pin"; fi
if [ "$(grep -c '(Recommended' <<<"$(sed -n '/^## § Re-pin/,$p' "$RF")")" = 0 ] && grep -qF 'No recommendation. The options are equivalent' <<<"$(sed -n '/^## § Re-pin/,$p' "$RF")" && grep -qF 'never auto-resolve it' "$RF"; then ok "re-pin question is an unconditional gate with no recommendation"; else no "re-pin question is an unconditional gate with no recommendation"; fi
rp() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" HEADSHA="${HS-$OH}" TH="${TH-$OH}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; n1_fullauto_enabled() { echo "${FA_KEY-false}"; }; '"$RP" 2>&1); }
fx 5.10.0 5.12.0 5.11.0; rm -f "$PIN"
for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; FA_KEY=true rp; unset "${g%%=*}"
  line "repin: denied with $g" "repin:denied"
done
gw checkout -q main; rp; gw checkout -q feat
line "repin: wrong branch refused" "repin:branch"
XREPO=true rp
line "repin: fork PR refused" "repin:branch"
gw commit -q --allow-empty -m local; rp; gw reset -q --hard "$OH"
line "repin: local tip != remote head refused" "repin:tip"
if [ ! -e "$PIN" ]; then ok "repin: refusals write no pin"; else no "repin: refusals write no pin"; fi
rp
line "repin: pinless PR pinned at its head" "pin:set ${OH:0:7}"
if [ "$(cat "$PIN" 2>/dev/null)" = "$OH" ]; then ok "repin: pin file holds the head"; else no "repin: pin file holds the head"; fi
rp
line "repin: an existing pin is never overwritten" "repin:pinned"
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
NOCK="ERR:no checks reported on the 'feat' branch|CLEAN"
POLLS=3 WD="$T/nowf" ci "$NOCK" "$PS|CLEAN"
line "ci: no checks then checks passes on real checks" "ci:pass"
if [ "$(cat "$T/cin")" = 2 ]; then ok "ci: no-checks poll 1 does not pass"; else no "ci: no-checks poll 1 does not pass"; fi
POLLS=2 WD="$T/pu/.github" ci "$NOCK"
line "ci: no checks within the grace count times out" "ci:timeout"
POLLS=5 WD="$T/pu/.github" ci "$NOCK"
line "ci: no checks for all grace polls passes (any CI, no pull_request workflow)" "ci:pass"
if [ "$(cat "$T/cin")" = 3 ]; then ok "ci: grace is 3 polls"; else no "ci: grace is 3 polls"; fi
POLLS=6 WD="$T/pu/.github" ci "$NOCK" "$NOCK" '[{"bucket":"pending"}]|CLEAN' "$NOCK"
line "ci: no-check streak resets when checks appear" "ci:pass"
if [ "$(cat "$T/cin")" = 6 ]; then ok "ci: grace restarts after a pending poll"; else no "ci: grace restarts after a pending poll"; fi
POLLS=5 ci "$NOCK"
line "ci: pull_request workflow never passes on no checks" "ci:timeout"
POLLS=5 WD="$T/pu/.github" ci "$NOCK" "ERR:boom|CLEAN" "$NOCK" "ERR:boom|CLEAN" "$NOCK"
line "ci: API errors interrupt the no-check streak" "ci:timeout"
# N1-142: references/repin.md (missing or foreign pin -> re-review, lease push, re-pin), interactive only.
PF=skills/n1-finish/references/repin.md
if grep -qF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$PF" && ! grep -qF '(Recommended)' "$PF"; then ok "repin offer uses the verbatim no-recommendation form"; else no "repin offer uses the verbatim no-recommendation form"; fi
if grep -qF 'Verdict: PASS' "$PF" && grep -qF '/n1:n1-review' "$PF"; then ok "repin pins only after a PASS re-review"; else no "repin pins only after a PASS re-review"; fi
PF1=$(block 1 "$PF"); PF2=$(block 2 "$PF")
if [ -n "$(block 3 "$PF")" ] && [ "$(block 3 "$PF")" = "$(block 3 "$RF")" ]; then ok "repin CI wait is the resolve-dirty CI wait verbatim"; else no "repin CI wait is the resolve-dirty CI wait verbatim"; fi
if grep -qF -- '--force-with-lease="$BR:$H"' <<<"$PF2" && ! grep -qE -- '--force( |$)|push -f' "$PF"; then ok "repin push uses a lease on the PR head, never a bare force"; else no "repin push uses a lease on the PR head, never a bare force"; fi
rp() { OUT=$(cd "$G/w" && PATH="$T/bin:$PATH" TH="${TH-$OH}" HEADSHA="${HS-$OH}" bash -c 'source "$CFG"; n1_finish_merge_enabled() { echo "${MERGE_KEY-true}"; }; n1_fullauto_enabled() { echo "${FA_KEY-false}"; }; '"$1" 2>&1); }

# Gating (AC4): queue/headless are denied even with mergeOnFinish and fullAuto both true.
fx 5.10.0 5.12.0 5.11.0; rm -f "$PIN"
for g in "MERGE_KEY=false" "N1_QUEUE_RUN_ID=q1" "N1_HEADLESS=1"; do
  export "$g"; FA_KEY=true rp "$PF1"
  has "repin preflight: denied with $g" "repin:denied"
  FA_KEY=true rp "$PF2"; unset "${g%%=*}"
  has "repin push: denied with $g" "repin:denied"
done
if [ ! -f "$PIN" ] && [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ]; then ok "repin: denied runs push and pin nothing"; else no "repin: denied runs push and pin nothing"; fi

# Preflight: PR branch checked out at the PR head, clean, not a fork.
rp "$PF1"
line "repin preflight: on the PR branch at the PR head" "repin:ok head:$OH branch:feat"
gw checkout -q main; rp "$PF1"; gw checkout -q feat
has "repin preflight: wrong branch skipped" "repin:skip branch"
TH=$S rp "$PF1"
has "repin preflight: local tip not at the PR head skipped" "repin:skip local-tip"
echo x >> "$G/w/src.txt"; rp "$PF1"; gw checkout -q -- src.txt
has "repin preflight: uncommitted changes skipped" "repin:skip dirty"
XREPO=true rp "$PF1"
has "repin preflight: fork PR skipped" "repin:skip fork"
HEADREF=main rp "$PF1"
has "repin preflight: head == base skipped" "repin:skip fork"
TN='7;x' rp "$PF1"
has "repin preflight: non-digit PR rejected" "pr:invalid"
TH=abc rp "$PF1"
has "repin preflight: bad head rejected" "head:invalid"

# Missing pin, review made no fixes: nothing pushed, the PR head itself is pinned (AC2).
rp "$PF2"
has "repin push: set reported" "pin:set ${OH:0:7}"
line "repin push: no fixes pins the PR head" "repin:done $OH"
if [ "$(cat "$PIN")" = "$OH" ] && ! grep -qF 'pushed:' <<<"$OUT"; then ok "repin push: no fixes pushes nothing"; else no "repin push: no fixes pushes nothing"; fi

# Foreign pin + a review-fix commit: lease push, then pin the new head (set overwrites the old pin).
echo "$S" > "$PIN"; echo fix > "$G/w/fix.txt"; gw add fix.txt; gw commit -qm "review fix"; NH=$(gw rev-parse HEAD)
HS=$NH rp "$PF2"
has "repin push: review fixes pushed" "pushed:${NH:0:7}"
line "repin push: new head pinned" "repin:done $NH"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$NH" ] && [ "$(cat "$PIN")" = "$NH" ]; then ok "repin push: origin and pin at the reviewed head"; else no "repin push: origin and pin at the reviewed head"; fi

# set refuses when the PR head on GitHub is not the local tip: the old pin stays, merge stays blocked.
echo "$S" > "$PIN"; TH=$NH HS=$O rp "$PF2"
line "repin push: PR head != local tip fails" "repin:failed"
if [ "$(cat "$PIN")" = "$S" ]; then ok "repin push: failed set keeps the old pin"; else no "repin push: failed set keeps the old pin"; fi

# Remote moved since 3.1: the lease rejects the push, nothing is pinned.
fx 5.10.0 5.12.0 5.11.0; rm -f "$PIN"
echo fix > "$G/w/fix.txt"; gw add fix.txt; gw commit -qm "review fix"; NH=$(gw rev-parse HEAD)
git clone -q "$G/o.git" "$G/x" && git -C "$G/x" checkout -q feat && echo other > "$G/x/other.txt" \
  && git -C "$G/x" add other.txt && git -C "$G/x" commit -qm other && git -C "$G/x" push -q origin feat
RFH=$(git -C "$G/o.git" rev-parse feat)
HS=$NH rp "$PF2"
has "repin push: lease rejects a remote moved since 3.1" "push:rejected"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$RFH" ] && [ ! -f "$PIN" ]; then ok "repin push: rejected push leaves origin and pins nothing"; else no "repin push: rejected push leaves origin and pins nothing"; fi

# History rewritten during review (local tip not a descendant of the PR head): refused before any push.
fx 5.10.0 5.12.0 5.11.0; rm -f "$PIN"; gw commit -q --amend -m amended
rp "$PF2"
has "repin push: rewritten history refused" "push:skip"
if [ "$(git -C "$G/o.git" rev-parse feat)" = "$OH" ] && [ ! -f "$PIN" ]; then ok "repin push: rewrite refusal pushes and pins nothing"; else no "repin push: rewrite refusal pushes and pins nothing"; fi
exit $FAIL
