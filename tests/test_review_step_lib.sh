#!/usr/bin/env bash
# N1-436: lib/review-step.sh runs the review step's entry and collect blocks.
# Run: bash tests/test_review_step_lib.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
lacks() { if [[ "$2" == *"$3"* ]]; then no "$1 (unexpected: $3)"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/review-step.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_STORY_ID N1_STORY_BRANCH N1_QUEUE_RUN_ID N1_RUN_ID BREAK_CHECK_TQ
export N1_HOME="$T/home" ID="RV-1"
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM"
REPO="$T/repo"; git init -q "$REPO"; git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# --- n1_review_entry ---
OUT=$(n1_review_entry "$REPO" 2>&1); rc=$?
eq "entry: missing implementation.md returns 1" "1" "$rc"
has "entry: abort message" "$OUT" "implementation.md missing"

printf '# Impl\n' > "$MEM/implementation.md"; printf 'origin/feat-base' > "$MEM/branch-point"; printf 'old\n' > "$MEM/review-cr.md"
OUT=$(n1_review_entry "$REPO" 2>&1); rc=$?
eq "entry: returns 0" "0" "$rc"
has "entry: base from branch-point" "$OUT" "BASE_BRANCH=origin/feat-base RELATED_ENABLED="
has "entry: cycle 0 is full scope" "$OUT" "CYCLE=0 INCREMENTAL=false"
has "entry: prints tree snapshot" "$OUT" "TREE_BEFORE=$(n1_tree_snapshot "$REPO")"
lacks "entry: no FIX_FILES on full scope" "$OUT" "FIX_FILES="
if [ -e "$MEM/review-cr.md" ]; then no "entry: removes stale reviewer files"; else ok "entry: removes stale reviewer files"; fi
eq "entry: writes review spec" "# Review Spec (generated)" "$(head -1 "$MEM/review-spec.md")"
eq "entry: writes qa facts" "# QA Facts (generated)" "$(head -1 "$MEM/qa-facts.md")"

printf -- '---\nreview_fix_cycle: 1\n---\n' > "$MEM/overview.md"
printf '+fix\n' > "$MEM/fix.diff"; printf 'a.sh\nb.sh\n' > "$MEM/fix-changed-files"; printf '### Verdict: FAIL\n' > "$MEM/review.md"
OUT=$(n1_review_entry "$REPO" 2>&1)
has "entry: cycle 1 with fix.diff is incremental" "$OUT" "CYCLE=1 INCREMENTAL=true"
has "entry: prints FIX_FILES" "$OUT" "FIX_FILES=a.sh b.sh"
eq "entry: keeps previous review" "### Verdict: FAIL" "$(cat "$MEM/review-prev.md")"
printf -- '---\nreview_fix_cycle: x\n---\n' > "$MEM/overview.md"
has "entry: non-numeric cycle becomes 1" "$(n1_review_entry "$REPO" 2>&1)" "CYCLE=1"
printf 'x\n' > "$MEM/review-status.md"; n1_review_entry "$REPO" >/dev/null 2>&1
if [ -e "$MEM/review-status.md" ]; then no "entry: removes stale review-status.md"; else ok "entry: removes stale review-status.md"; fi

# --- n1_review_collect ---
rm -f "$MEM/review.md" "$MEM/overview.md" "$MEM/fp-new.tsv"
put_reviews() { printf '### Verdict: PASS\n' > "$MEM/review-hdr.md"; printf '## CR\n' > "$MEM/review-cr.md"; printf '## SEC\n' > "$MEM/review-sec.md"; }
put_reviews
OUT=$(n1_review_collect true 2>&1); rc=$?
eq "collect: returns 0" "0" "$rc"
eq "collect: review.md = header, CR, SEC" '### Verdict: PASS|## CR|## SEC|' "$(tr '\n' '|' < "$MEM/review.md")"
has "collect: TQ_MAX defaults to 2" "$OUT" "TQ_MAX=2"
n1_review_collect false >/dev/null 2>&1
eq "collect: SEC omitted when not spawned" '### Verdict: PASS|## CR|' "$(tr '\n' '|' < "$MEM/review.md")"
for m in review-hdr.md review-cr.md review-sec.md; do
    rm -f "$MEM/$m" "$MEM/review.md"
    OUT=$(n1_review_collect true 2>&1); rc=$?
    if [ "$rc" = 1 ] && [[ "$OUT" == *"PARTIAL: $m missing/empty"* ]] && [ ! -e "$MEM/review.md" ]; then ok "collect: missing $m is PARTIAL"; else no "collect: missing $m is PARTIAL"; fi
    put_reviews
done
printf 'CR-1\tHigh\ta.sh\tone\nCR-2\tCritical\tb.sh\ttwo\n' > "$MEM/fp-new.tsv"
n1_review_collect false >/dev/null 2>&1
eq "collect: records cycle-0 fingerprints" "2" "$(n1_fingerprint_blocking_count_for_cycle "$MEM/fingerprints.jsonl" 0)"
printf -- '---\nreview_fix_cycle: 1\n---\n' > "$MEM/overview.md"
printf 'CR-3\tHigh\tc.sh\tthree\nCR-4\tHigh\td.sh\tfour\n' > "$MEM/fp-new.tsv"
rm -f "$MEM/review-prev.md"
has "collect: without review-prev.md, equal blockers at cycle 1 are NON_CONVERGING (count fallback)" "$(n1_review_collect false 2>&1)" "NON_CONVERGING: cycle 1"
# N1-569: per-finding states replace the count when review-prev.md exists
printf '### Verdict: FAIL\n- [CR-1] High a.sh:1 — one\n- [CR-2] High b.sh:2 — two\n' > "$MEM/review-prev.md"
printf '### Verdict: FAIL\n- [CR-1] High a.sh:1 — one\n- [CR-3] High c.sh:3 — three\n' > "$MEM/review-hdr.md"
printf -- '- [CR-1] OPEN\n- [CR-2] FIXED\n' > "$MEM/review-status.md"; printf '+fix\n' > "$MEM/fix.diff"
OUT=$(n1_review_collect false 2>&1)
has "collect: prints per-finding states" "$OUT" "FIX_STATES: resolved=1 carried=1 new=1 unlabeled=0"
lacks "collect: 2 High -> 2 High with one resolved and one new is not NON_CONVERGING" "$OUT" "NON_CONVERGING"
printf '### Verdict: FAIL\n- [CR-1] High a.sh:1 — one\n- [CR-2] High b.sh:2 — two\n' > "$MEM/review-hdr.md"
printf -- '- [CR-1] OPEN\n- [CR-2] OPEN\n' > "$MEM/review-status.md"
has "collect: nothing resolved and something carried is NON_CONVERGING" "$(n1_review_collect false 2>&1)" "NON_CONVERGING: cycle 1"
: > "$MEM/fix.diff"; lacks "collect: empty fix.diff skips the states (stale review-prev.md)" "$(n1_review_collect false 2>&1)" "FIX_STATES:"

# --- step wiring: execute the step's own fences so the call text itself is tested ---
STEP="$REPO_ROOT/skills/n1-start/steps/review.md"
fence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1" | sed '\#^source ~/.n1/preamble.sh$#d'; }
n1_step_begin() { :; }; n1_step_end() { :; }
rm -f "$MEM/overview.md" "$MEM/fp-new.tsv"
OUT=$( cd "$REPO" && eval "$(fence "$STEP" 1 | sed "s#<worktree dir>#$REPO#")" 2>&1 ); rc=$?
eq "wiring: entry fence exits 0" "0" "$rc"
has "wiring: entry fence prints base and cycle" "$OUT" "BASE_BRANCH=origin/feat-base RELATED_ENABLED="
has "wiring: entry fence prints TREE_BEFORE" "$OUT" "TREE_BEFORE="
put_reviews
OUT=$( cd "$REPO" && eval "$(fence "$STEP" 3 | sed 's/<true if security-reviewer was spawned, else false>/false/')" 2>&1 ); rc=$?
eq "wiring: collect fence exits 0" "0" "$rc"
has "wiring: collect fence prints TQ_MAX" "$OUT" "TQ_MAX=2"
eq "wiring: collect fence writes review.md" '### Verdict: PASS|## CR|' "$(tr '\n' '|' < "$MEM/review.md")"
rm -f "$MEM/review-hdr.md"
( cd "$REPO" && eval "$(fence "$STEP" 3 | sed 's/<true if security-reviewer was spawned, else false>/false/')" ) >/dev/null 2>&1; rc=$?
eq "wiring: collect fence stops on PARTIAL" "1" "$rc"

# N1-483: cycle-0 blocking Index count (review.md FAIL rule) and its overview persistence.
HDR="$T/hdr-c0.md"
printf '%s\n' '### Verdict: FAIL' 'Index:' \
    '- [CR-1] High a.sh:1 — t1' \
    '- [CR-2] Medium a.sh:2 — t2' \
    '- [RULE-1] Low a.sh:3 — t3' \
    '- [TQ-1] Critical t.sh:4 — t4' \
    '- [SEC-1] Medium b.sh:5 — t5' \
    '- [SEC-2] Low b.sh:6 — t6' \
    '- [SEC-3] Critical b.sh:7 — t7 (pre-existing)' \
    '- [XREPO-1] Low c.sh:8 — t8' > "$HDR"
eq "blocking index: Critical/High, any RULE, in-diff non-Low SEC" "4" "$(n1_review_blocking_index_count "$HDR")"
printf '### Verdict: PASS\nIndex:\n(none)\n' > "$HDR"
eq "blocking index: (none) counts 0" "0" "$(n1_review_blocking_index_count "$HDR")"
n1_review_blocking_index_count "$T/no-such-hdr.md" >/dev/null; rc=$?
eq "blocking index: missing file returns 1" "1" "$rc"

printf -- '---\nreview_fix_cycle: 0\n---\n# O\n' > "$MEM/overview.md"
printf '%s\n' '### Verdict: FAIL' '- [CR-1] High a.sh:1 — t1' '- [RULE-2] Low a.sh:2 — t2' '- [CR-3] Low a.sh:3 — t3' > "$MEM/review-hdr.md"
printf '## CR\n' > "$MEM/review-cr.md"
n1_review_collect false >/dev/null 2>&1
eq "collect: cycle 0 persists review_c0_blocking" "2" "$(n1_read_frontmatter "$MEM/overview.md" review_c0_blocking)"
printf -- '---\nreview_fix_cycle: 1\n---\n# O\n' > "$MEM/overview.md"
n1_review_collect false >/dev/null 2>&1
eq "collect: later cycles never write review_c0_blocking" "" "$(n1_read_frontmatter "$MEM/overview.md" review_c0_blocking)"

# N1-275: the pre-existing downgrade diff obtains its own base; any missing input means no diff (exit 1, no downgrade).
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
printf 'x\n' > "$REPO/new.sh"; git -C "$REPO" add new.sh; git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m feat
RP="$REPO_ROOT/skills/n1-start/procedures/review-preexisting.md"
pre() { ( cd "$REPO" && unset BASE_BRANCH && eval "$(fence "$RP" 1 | sed "s#<worktree dir>#$REPO#")" ) 2>/dev/null; }
printf '%s' "$BASE_SHA" > "$MEM/branch-point"
OUT=$(pre); rc=$?
eq "preexisting: branch-point base exits 0" "0" "$rc"
has "preexisting: prints the base...HEAD hunks" "$OUT" "+++ b/new.sh"
rm -f "$MEM/branch-point"
OUT=$(pre); rc=$?
eq "preexisting: no base source exits 1" "1" "$rc"
eq "preexisting: no base source prints nothing" "" "$OUT"
: > "$MEM/branch-point"
OUT=$(pre); rc=$?
eq "preexisting: empty branch-point exits 1" "1" "$rc"
printf 'origin/no-such-ref' > "$MEM/branch-point"
OUT=$(pre); rc=$?
eq "preexisting: unresolvable base exits 1" "1" "$rc"
eq "preexisting: unresolvable base prints nothing" "" "$OUT"
git -C "$REPO" rev-parse HEAD > "$MEM/branch-point"
OUT=$(pre); rc=$?
eq "preexisting: empty diff exits 1" "1" "$rc"
printf '%s' "$BASE_SHA" > "$MEM/branch-point"
OUT=$( export N1_STORY_BRANCH="bad..branch"; pre ); rc=$?
eq "preexisting: invalid story base exits 1" "1" "$rc"
( cd "$REPO" && n1_review_preexisting_diff "$T/no-such-dir" ) >/dev/null 2>&1; rc=$?
eq "preexisting: non-directory worktree exits 1" "1" "$rc"
( cd "$REPO" && n1_review_preexisting_diff "" ) >/dev/null 2>&1; rc=$?
eq "preexisting: empty worktree arg exits 1" "1" "$rc"

exit $FAIL
