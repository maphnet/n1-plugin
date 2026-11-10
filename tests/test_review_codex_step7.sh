#!/usr/bin/env bash
# N1-517: Step 7 Codex pass (background start, collect, index, receipt coverage), Step 8 scope gate,
# n1-pr skip wiring, n1-implement run mode n1-start, telemetry implementation tag.
# Run: bash tests/test_review_codex_step7.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
lacks() { if [[ "$2" == *"$3"* ]]; then no "$1 (unexpected: $3)"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }
line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d: -f1; }   # first line number of a fixed string, empty if absent

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_STORY_ID N1_STORY_BRANCH N1_QUEUE_RUN_ID N1_RUN_ID N1_REVIEW_BRANCH N1_REVIEW_DIR BREAK_CHECK_TQ
export N1_HOME="$T/home" N1_STATE_DIR="$T/state" N1_SESSION_ID=cx-test ID="CX-1"
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM" "$T/bin"; printf '{}\n' > "$N1_HOME/config.json"
source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/codex-review.sh"
gc() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q "$@"; }
REPO="$T/repo"; git init -q -b user/CX-1 "$REPO"; cd "$REPO" || exit 1
gc --allow-empty -m base; BASE_SHA=$(git rev-parse HEAD); git update-ref refs/remotes/origin/main "$BASE_SHA"
echo a > a.txt; git add a.txt; gc -m change
BR=$(git branch --show-current)

# --- n1_review_codex_covered (lib/codex-review.sh) ---
if n1_review_codex_covered; then no "covered: false without marker"; else ok "covered: false without marker"; fi
git rev-parse HEAD > "$MEM/codex-step7"
if n1_review_codex_covered; then no "covered: false without a receipt"; else ok "covered: false without a receipt"; fi
n1_review_record "$BR" ran "" true none
if n1_review_codex_covered; then ok "covered: marker + ran receipt"; else no "covered: marker + ran receipt"; fi
printf '%040d\n' 0 | tr 0 a > "$MEM/codex-step7"
if n1_review_codex_covered; then no "covered: false when marker head is not an ancestor"; else ok "covered: false when marker head is not an ancestor"; fi
git rev-parse HEAD > "$MEM/codex-step7"
( ID=""; if n1_review_codex_covered; then echo bad; fi ) | grep -q bad && no "covered: false with empty ID" || ok "covered: false with empty ID"
n1_review_record "$BR" skipped no-auth true none
if n1_review_codex_covered; then no "covered: false for a skipped receipt"; else ok "covered: false for a skipped receipt"; fi
n1_review_record "$BR" failed codex-exit-1 true none
if n1_review_codex_covered; then no "covered: false for a failed receipt"; else ok "covered: false for a failed receipt"; fi
rm -f "$MEM/codex-step7"; rm -rf "$N1_STATE_DIR/review-receipts"

# --- end of sections ---
echo "N1-517 step7 codex tests: FAIL=$FAIL"
exit "$FAIL"
