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
ov abc; eq "T4b non-numeric counter -> allow" "allow" "$(n1_review_fix_gate "$OV")"

# ---- gate: explicit config wins ----
cfg '{"review":{"maxFixAttempts":2}}'
ov 1; eq "T3 cap 2, counter 1 -> allow" "allow" "$(n1_review_fix_gate "$OV")"
ov 2; eq "T3b cap 2, counter 2 -> exhausted" "exhausted" "$(n1_review_fix_gate "$OV")"
cfg '{"review":{"maxFixAttempts":0}}'
ov 0; eq "T3c cap 0 -> exhausted at once" "exhausted" "$(n1_review_fix_gate "$OV")"
cfg '{"review":{"maxFixAttempts":"x"}}'
ov 0; eq "T5 non-numeric cap -> default 1 (allow at 0)" "allow" "$(n1_review_fix_gate "$OV")"
ov 1; eq "T5b non-numeric cap -> default 1 (exhausted at 1)" "exhausted" "$(n1_review_fix_gate "$OV")"

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

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
