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
has "collect: equal blockers at cycle 1 are NON_CONVERGING" "$(n1_review_collect false 2>&1)" "NON_CONVERGING: cycle 1"

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

exit $FAIL
