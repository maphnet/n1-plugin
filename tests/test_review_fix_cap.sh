#!/usr/bin/env bash
# tests/test_review_fix_cap.sh -- N1-211: the review fix cap holds in code (n1_review_fix_gate),
# survives resume (counter lives in overview.md), and gates every developer dispatch in fix.md.
# Run: bash tests/test_review_fix_cap.sh   (clean: env -i PATH=/usr/local/bin:/usr/bin:/bin bash tests/test_review_fix_cap.sh)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="${HOME:-$T}"
source lib/config.sh
source lib/frontmatter.sh

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"
OV="$T/overview.md"
cfg() { printf '%s\n' "$1" > "$N1_HOME/config.json"; }
ov() { printf -- '---\nstep: fix\nreview_fix_cycle: %s\n---\n' "$1" > "$OV"; }

# ---- gate: default cap 1 ----
cfg '{}'
ov 0; eq "T1 counter 0, default cap -> allow" "allow" "$(n1_review_fix_gate "$OV")"
ov 1; eq "T2 counter 1, default cap -> exhausted" "exhausted" "$(n1_review_fix_gate "$OV")"
n1_review_fix_gate "$OV" >/dev/null; eq "T2b exhausted returns 1" "1" "$?"
printf -- '---\nstep: fix\n---\n' > "$OV"; eq "T4 absent counter -> allow" "allow" "$(n1_review_fix_gate "$OV")"
ov abc; eq "T4b non-numeric counter -> exhausted (fail closed)" "exhausted" "$(n1_review_fix_gate "$OV")"

# ---- gate: explicit config wins ----
cfg '{"review":{"maxFixAttempts":2}}'
ov 1; eq "T3 cap 2, counter 1 -> allow" "allow" "$(n1_review_fix_gate "$OV")"
ov 2; eq "T3b cap 2, counter 2 -> exhausted" "exhausted" "$(n1_review_fix_gate "$OV")"
cfg '{"review":{"maxFixAttempts":0}}'
ov 0; eq "T3c cap 0 -> exhausted at once" "exhausted" "$(n1_review_fix_gate "$OV")"
cfg '{"review":{"maxFixAttempts":"x"}}'
ov 0; eq "T5 non-numeric cap -> default 1 (allow at 0)" "allow" "$(n1_review_fix_gate "$OV")"
ov 1; eq "T5b non-numeric cap -> default 1 (exhausted at 1)" "exhausted" "$(n1_review_fix_gate "$OV")"

ov abc; n1_increment_counter "$OV" review_fix_cycle >/dev/null 2>&1; eq "T6 increment refuses non-numeric counter" "abc" "$(n1_read_frontmatter "$OV" review_fix_cycle)"

# ---- breach: reproduce (pre-N1-211 nothing compared the counter), then prevent ----
cfg '{}'
ungated() { echo allow; }
run_fails() { # <gate-fn> <review FAILs> -> final review_fix_cycle
    local i; ov 0
    for ((i = 0; i < $2; i++)); do "$1" "$OV" >/dev/null && n1_increment_counter "$OV" review_fix_cycle >/dev/null; done
    n1_read_frontmatter "$OV" review_fix_cycle
}
eq "R1 reproduce: ungated loop breaches the cap (5 dispatches)" "5" "$(run_fails ungated 5)"
eq "R2 prevent: gated loop stops at default cap 1" "1" "$(run_fails n1_review_fix_gate 5)"
cfg '{"review":{"maxFixAttempts":2}}'
eq "R3 prevent: gated loop stops at configured cap 2" "2" "$(run_fails n1_review_fix_gate 5)"

# ---- resume: one fix cycle in this process, gate re-read in a fresh process ----
cfg '{}'; ov 0
n1_review_fix_gate "$OV" >/dev/null && n1_increment_counter "$OV" review_fix_cycle >/dev/null
RESUMED=$(bash -c 'source lib/config.sh; source lib/frontmatter.sh; n1_review_fix_gate "$1"' _ "$OV")
eq "R4 resume after a fix cycle -> exhausted, no second dispatch" "exhausted" "$RESUMED"

# ---- defaults agree ----
eq "D1 pipeline.json review_fix max_default is 1" "1" "$(grep -cE '"name": "review_fix",.*"max_default": 1 ' pipeline.json)"

# ---- wiring: fix.md ----
F=skills/n1-start/steps/fix.md
GATE_LN=$(awk '/^[[:space:]]*```/{b=!b; next} b && /n1_review_fix_gate/{print NR; exit}' "$F")
SPAWN_LN=$(grep -n 'spawn developer' "$F" | head -1 | cut -d: -f1)
eq "W1 fix.md calls the gate in a fence before the first developer spawn" "yes" "$([ -n "$GATE_LN" ] && [ -n "$SPAWN_LN" ] && [ "$GATE_LN" -lt "$SPAWN_LN" ] && echo yes || echo no)"
eq "W2 cap gate covers SOFT-ONLY and FAIL" "1" "$(grep -cE '^\*\*Cap gate\*\*.*SOFT-ONLY.*FAIL' "$F")"
eq "W3 FAIL and SOFT-ONLY prompts both define N" "2" "$(grep -c 'N = REVIEW_FIX_CYCLE+1' "$F")"
eq "W4 FAIL-only block writes the fix diff" "1" "$(grep -cF 'git diff "$PRE_FIX_SHA" HEAD > "$N1_HOME/memory/$ID/fix.diff"' "$F")"
eq "W5 exhausted hands-off records For Human Review" "1" "$(grep -cE '^\*\*Exhausted\*\*.*## For Human Review' "$F")"
eq "W6 fix.md no longer claims review default 2" "0" "$(grep -c 'maxFixAttempts` (default 2)' "$F")"

# ---- wiring: review.md ----
R=skills/n1-start/steps/review.md
eq "V1 re-review is incremental from cycle 1 on the fix diff" "1" "$(grep -cF '[ "$CYCLE" -ge 1 ] && [ -s "$N1_HOME/memory/$ID/fix.diff" ]' "$R")"
eq "V2 incremental reviewers get only the fix diff" "1" "$(grep -cE 'INCREMENTAL=true.*fix\.diff.*review only the changes' "$R")"
eq "V3 review.md no longer claims default 2" "0" "$(grep -c 'maxFixAttempts` (default 2)' "$R")"
eq "V4 review FAIL routes to the fix-step cap gate" "1" "$(grep -cF '**FAIL → Step 8** (its **Cap gate** bounds the loop).' "$R")"

eq "V5 security-reviewer keeps full scope on re-review" "1" "$(grep -cF 'security-reviewer keeps full scope' "$R")"
eq "V6 CYCLE guarded as numeric (both sites)" "2" "$(grep -cF '[[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1' "$R")"
eq "V7 fix.md increments the counter before the developer dispatch (resume-safe)" "yes" "$(il=$(grep -n 'n1_increment_counter.*review_fix_cycle' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); sp=$(grep -n 'spawn developer' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); [ -n "$il" ] && [ "$il" -lt "$sp" ] && echo yes || echo no)"
eq "V8 cycle emit MAX has a source" "1" "$(grep -c 'echo "MAX=\$REVIEW_FIX_MAX"' skills/n1-start/steps/fix.md)"
eq "V9 incremental code-reviewer gets prior findings" "1" "$(grep -cF 'review-prev.md: re-report' "$R")"

# ---- wiring: PR body + telemetry ----
eq "P1 tech-writer renders For Human Review" "1" "$(grep -cE 'review\.md has `## For Human Review`.*mandatory' agents/tech-writer.md)"
eq "P2 pr.md emits review_unresolved_at_pr" "1" "$(grep -c '"review_unresolved_at_pr=' skills/n1-start/steps/pr.md)"

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
