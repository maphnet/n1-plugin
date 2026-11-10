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

# --- Step 7 start / collect / index (lib/review-step.sh) ---
source "$REPO_ROOT/lib/review-step.sh"
cat > "$T/bin/codex" <<'SH'
#!/usr/bin/env bash
[ "$1" = login ] && exit 0
[ "${REVIEW_MODE:-ok}" != fail ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf '%s\n' "${CODEX_OUT:-No findings.}" > "$2"; break; fi
  shift
done
SH
chmod +x "$T/bin/codex"; export PATH="$T/bin:$PATH" N1_CODEX_COLLECT_WAIT=20 N1_CODEX_AUTH_TIMEOUT=5
rm -f "$MEM/overview.md"
OUT=$(n1_review_codex_start origin/main)
eq "start: cycle 0 starts codex on the merge-base" "codex:started base=$BASE_SHA" "$OUT"
OUT=$(n1_review_codex_collect)
has "collect: prints base" "$OUT" "codex:base=$BASE_SHA"
has "collect: one-line No findings. -> findings:none" "$OUT" "codex:ran findings:none"
eq "collect: marker holds HEAD" "$(git rev-parse HEAD)" "$(cat "$MEM/codex-step7" 2>/dev/null)"
if n1_review_codex_covered; then ok "collect: ran run covers the branch"; else no "collect: ran run covers the branch"; fi
eq "start: skip when already covered" "codex:skip reason=covered" "$(n1_review_codex_start origin/main)"

rm -f "$MEM/codex-step7"; export CODEX_OUT=$'**High** - x\n[P2] y'
n1_review_codex_start origin/main >/dev/null; OUT=$(n1_review_codex_collect)
has "collect: findings -> fenced findings file" "$OUT" "codex:ran findings:file=$N1_HOME/scratch/codex-findings-"
[ -f "$MEM/codex-step7" ] && ok "collect: findings run writes the marker" || no "collect: findings run writes the marker"

rm -f "$MEM/codex-step7"; export REVIEW_MODE=fail
n1_review_codex_start origin/main >/dev/null; OUT=$(n1_review_codex_collect)
has "collect: failed run -> codex:none" "$OUT" "codex:none outcome=failed"
[ -f "$MEM/codex-step7" ] && no "collect: failed run writes no marker" || ok "collect: failed run writes no marker"
unset REVIEW_MODE CODEX_OUT

printf -- '---\nreview_fix_cycle: 1\n---\n' > "$MEM/overview.md"; printf 'keep\n' > "$MEM/review-codex.md"
eq "start: no Codex at cycle >= 1" "codex:skip reason=cycle" "$(n1_review_codex_start origin/main)"
[ -s "$MEM/review-codex.md" ] && ok "start: cycle >= 1 keeps review-codex.md" || no "start: cycle >= 1 keeps review-codex.md"
rm -f "$MEM/overview.md"
printf '{"crossHostReview":{"autoTriage":false}}\n' > "$N1_HOME/config.json"
eq "start: skip when autoTriage is off" "codex:skip reason=autotriage-off" "$(n1_review_codex_start origin/main)"
[ -e "$MEM/review-codex.md" ] && no "start: stale review-codex.md removed on an uncovered cycle-0 skip" || ok "start: stale review-codex.md removed on an uncovered cycle-0 skip"
printf '{}\n' > "$N1_HOME/config.json"
eq "start: skip on an unresolvable base" "codex:skip reason=no-base" "$(n1_review_codex_start refs/does/not/exist)"
eq "start: skip without ID" "codex:skip reason=no-id" "$(ID="" n1_review_codex_start origin/main)"

rm -f "$MEM"/codex-bg.*
eq "collect: not started" "codex:none outcome=not-started" "$(n1_review_codex_collect)"
printf '%s %s\n' "$(( $(date +%s) - 2000 ))" "$BASE_SHA" > "$MEM/codex-bg.started"
has "collect: past the deadline -> timeout" "$(n1_review_codex_collect)" "codex:none outcome=timeout"
printf '%s %s\n' "$(date +%s)" "$BASE_SHA" > "$MEM/codex-bg.started"
has "collect: within the deadline -> pending" "$(N1_CODEX_COLLECT_WAIT=0 n1_review_codex_collect)" "codex:pending"
rm -f "$MEM"/codex-bg.* "$MEM/codex-step7"; rm -rf "$N1_STATE_DIR/review-receipts"

printf '%s\n' '## Codex Findings (validated)' \
  '- [CX-1] High lib/a.sh:12 — Off-by-one in loop' \
  '- [CX-2] Medium unknown:0 — Missing guard (security)' \
  '- [CX-3] High lib/a.sh:3 — runs `rm` here' \
  '- [CX-4] Severe lib/a.sh:3 — wrong tier' \
  '- [CX-5] Low lib/a b.sh:3 — space in path' \
  '### [CX-1] Off-by-one in loop' 'body text' > "$MEM/review-codex.md"
eq "index: only strict CX lines" $'- [CX-1] High lib/a.sh:12 — Off-by-one in loop\n- [CX-2] Medium unknown:0 — Missing guard (security)' \
  "$(n1_review_codex_index "$MEM/review-codex.md")"
eq "index: missing file prints nothing" "" "$(n1_review_codex_index "$MEM/nope.md")"

printf '### Verdict: FAIL\n' > "$MEM/review-hdr.md"; printf '## CR\n' > "$MEM/review-cr.md"
n1_review_collect false >/dev/null 2>&1
has "collect: cycle 0 appends review-codex.md" "$(cat "$MEM/review.md")" "## Codex Findings (validated)"
printf -- '---\nreview_fix_cycle: 1\n---\n' > "$MEM/overview.md"
n1_review_collect false >/dev/null 2>&1
lacks "collect: cycle >= 1 leaves review-codex.md out" "$(cat "$MEM/review.md")" "## Codex Findings (validated)"
rm -f "$MEM/review-codex.md"; printf -- '---\nreview_fix_cycle: 0\n---\n' > "$MEM/overview.md"
n1_review_collect false >/dev/null 2>&1; rc=$?
eq "collect: absent review-codex.md is not PARTIAL" "0" "$rc"
rm -f "$MEM/overview.md" "$MEM/review.md" "$MEM/review-hdr.md" "$MEM/review-cr.md"

# --- Step 8 scope gate (n1_review_fix_scope) ---
printf '%s %s\n' "$(date +%s)" "$BASE_SHA" > "$MEM/codex-bg.started"
START=$(git rev-parse HEAD); echo fix >> a.txt; gc -am in-scope
OUT=$(n1_review_fix_scope "$START")
has "fix scope: fix inside the branch diff is ok" "$OUT" "push:ok"
START=$(git rev-parse HEAD); echo out > b.txt; git add b.txt; gc -m out-of-scope
OUT=$(n1_review_fix_scope "$START")
has "fix scope: file outside the branch diff is blocked" "$OUT" "push:blocked"
has "fix scope: blocked commits are reset" "$OUT" "reset="
eq "fix scope: HEAD back at the pre-fix SHA" "$START" "$(git rev-parse HEAD)"
[ -e "$MEM/codex-gate-blocked" ] && no "fix scope: a clean reset leaves no push block" || ok "fix scope: a clean reset leaves no push block"
eq "fix scope: no new commit -> push:none" "push:none" "$(n1_review_fix_scope "$(git rev-parse HEAD)" | head -n 1)"
has "fix scope: invalid pre-fix SHA fails closed" "$(n1_review_fix_scope HEAD~1)" "kept="
[ -e "$MEM/codex-gate-blocked" ] && ok "fix scope: kept= writes the push block" || no "fix scope: kept= writes the push block"
rm -f "$MEM/codex-gate-blocked" "$MEM"/codex-bg.* "$MEM/codex-blocked-fix.patch"

# --- validate phase wiring (codex-triage-worker.md) ---
W="$REPO_ROOT/skills/n1-pr/procedures/codex-triage-worker.md"
WV=$(awk '/^## Phase: validate$/{p=1;next} p&&/^## Phase: /{exit} p' "$W")
has "validate: runs State, Severity Parsing and Validation only" "$WV" "never run **Fix Cycle**"
has "validate: writes review-codex.md" "$WV" "<memory>/review-codex.md"
has "validate: CX index line shape" "$WV" '`- [CX-<n>] <severity> <file>:<line> — <title>`'
has "validate: security-looking suffix" "$WV" '` (security)`'
has "validate: return line" "$WV" 'triage:validate state=<S> confirmed=<n> total=<m>'

# --- Step 7 wiring (review.md + procedures/review-codex.md) ---
RV="$REPO_ROOT/skills/n1-start/steps/review.md"; RC="$REPO_ROOT/skills/n1-start/procedures/review-codex.md"
has "review.md: cycle 0 reads review-codex.md" "$(cat "$RV")" 'procedures/review-codex.md'
has "review.md: Codex index lines go into review-hdr.md" "$(cat "$RV")" 'n1_review_codex_index'
[ -f "$RC" ] && ok "procedure exists" || no "procedure exists"
for s in 'n1_review_codex_start "<BASE_BRANCH' 'n1_review_codex_collect' 'phase: validate' 'n1_review_codex_index' 'never run at cycle >= 1'; do
  has "procedure: $s" "$(cat "$RC" 2>/dev/null)" "$s"
done
A=$(line_of 'codex:ran findings:file=' "$RC"); D=$(line_of 'phase: validate' "$RC")
[ -n "$A" ] && [ -n "$D" ] && [ "$A" -lt "$D" ] && ok "procedure: validator dispatched only after findings:file=" || no "procedure: validator dispatched only after findings:file="
has "procedure: findings:none dispatches nothing (AC6)" "$(cat "$RC" 2>/dev/null)" '`codex:ran findings:none`: no Codex findings; dispatch nothing'

# --- Step 8 wiring (fix.md) ---
FX="$REPO_ROOT/skills/n1-start/steps/fix.md"
G=$(line_of 'n1_review_fix_scope "$PRE_FIX_SHA"' "$FX"); D=$(line_of 'FIX_CHANGED=$(git diff --name-only "$PRE_FIX_SHA" HEAD)' "$FX")
[ -n "$G" ] && [ -n "$D" ] && [ "$G" -lt "$D" ] && ok "fix.md: scope gate runs before fix.diff" || no "fix.md: scope gate runs before fix.diff"
has "fix.md: gate only when CX findings exist" "$(cat "$FX")" "grep -q '^- \[CX-[0-9]'"
has "fix.md: kept= stops and escalates" "$(cat "$FX")" '`kept=` or `tree:restore-failed`: STOP and escalate'

# --- end of sections ---
echo "N1-517 step7 codex tests: FAIL=$FAIL"
exit "$FAIL"
