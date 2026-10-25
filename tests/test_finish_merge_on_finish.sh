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

# Nth bash block of 02-merge.md, placeholders bound to env vars.
block() { awk -v n="$1" '/^ *```bash/{c++; if(c==n){b=1;next}} b&&/^ *```/{exit} b' "$F" \
    | sed -e 's#^ *source ~/.n1/preamble.sh$#:#' -e 's/"<n>"/"${TN-7}"/' -e 's/"<head>"/"${TH-}"/' -e 's/"<mergeMethod>"/"${TMM-}"/'; }
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
  "repo view") R='{"nameWithOwner":"o/r"}' ;;
  "api graphql") [ -z "${GQL_ERR:-}" ] || exit 1; R=${GQL:-$DG} ;;
  "pr merge") echo "$*" >> "$LOG"; [ "${MERGE_EXIT:-0}" = 0 ] || { echo "merge blocked by branch protection" >&2; exit 1; }; exit 0 ;;
  "pr view") case "$*" in *headRefOid*) R="{\"headRefOid\":\"${HEADSHA:-}\",\"isDraft\":${DRAFT:-false},\"mergeStateStatus\":\"${MSS:-CLEAN}\"}" ;; *) R=${VIEW:-} ;; esac ;;
  *) exit 1 ;;
esac
if [ -n "$q" ]; then jq -r "$q" <<<"$R"; else echo "$R"; fi
EOF
chmod +x "$T/bin/gh"
S=0123456789abcdef0123456789abcdef01234567
O=fedcba9876543210fedcba9876543210fedcba98
export N1_HOME="$T/home" CFG="$ROOT/lib/config.sh"
PIN="$T/home/review-pins/o_r_7"; mkdir -p "${PIN%/*}"; echo "$S" > "$PIN"

pre() { OUT=$(cd "${WD:-$T}" && PATH="$T/bin:$PATH" HEADSHA=$S bash -c 'source "$CFG"; '"$PRE" 2>&1); }
CHECKS='[{"bucket":"pass"},{"bucket":"skipping"}]' pre
has "pre: green CI" "checks:fail=0 pending=0"
has "pre: head sha printed" "head:$S"
has "pre: no unresolved threads" "threads:0"
line "pre: reviewed-head pin printed" "pin:$S"
rm -f "$PIN"; CHECKS='[]' pre
line "pre: missing pin prints an empty pin" "pin:"
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

exit $FAIL
