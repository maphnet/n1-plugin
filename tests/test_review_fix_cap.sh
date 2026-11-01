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
run_fails() { # <gated 0|1> <review FAILs> -> final review_fix_cycle, real gate + real counter
    local i; ov 0
    for ((i = 0; i < $2; i++)); do
        { [ "$1" = 0 ] || n1_review_fix_gate "$OV" >/dev/null; } && n1_increment_counter "$OV" review_fix_cycle >/dev/null
    done
    n1_read_frontmatter "$OV" review_fix_cycle
}
eq "R1 reproduce: real counter without consulting the gate breaches cap 1 (5 dispatches)" "5" "$(run_fails 0 5)"
eq "R2 prevent: gated loop stops at default cap 1" "1" "$(run_fails 1 5)"
cfg '{"review":{"maxFixAttempts":2}}'
eq "R3 prevent: gated loop stops at configured cap 2" "2" "$(run_fails 1 5)"

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
cfg '{"review":{"maxFixAttempts":2}}'; ov 1
eq "W2b cap 2, counter 1 -> gate allow, yet fix.md still defers SOFT-ONLY at REVIEW_FIX_CYCLE>=1 (N1-261)" "allow:1" "$(n1_review_fix_gate "$OV"):$(grep -cE '^\*\*Cap gate\*\*.*SOFT-ONLY with `FIX_GATE` not `allow` or `REVIEW_FIX_CYCLE>=1`' "$F")"
eq "W3 FAIL and SOFT-ONLY prompts both define N" "2" "$(grep -c 'N = REVIEW_FIX_CYCLE+1' "$F")"
eq "W4 FAIL-only block writes the fix diff" "1" "$(grep -cF 'git diff "$PRE_FIX_SHA" HEAD > "$N1_HOME/memory/$ID/fix.diff"' "$F")"
eq "W5 exhausted hands-off records For Human Review" "1" "$(grep -cE '^\*\*Exhausted\*\*.*## For Human Review' "$F")"
eq "W6 fix.md no longer claims review default 2" "0" "$(grep -c 'maxFixAttempts` (default 2)' "$F")"
eq "W7a exhausted never recommends option 2" "0" "$(grep -c 'Recommended) on 2' "$F")"
eq "W7b exhausted always recommends option 1" "1" "$(grep -cF 'Always mark (Recommended) on 1' "$F")"
eq "W7c exhausted names open SEC IDs with severities" "1" "$(grep -cF 'Name open `[SEC-N]` IDs with severities' "$F")"

# ---- wiring: review.md ----
R=skills/n1-start/steps/review.md
eq "V1 re-review is incremental from cycle 1 on the fix diff" "1" "$(grep -cF '[ "$CYCLE" -ge 1 ] && [ -s "$N1_HOME/memory/$ID/fix.diff" ]' "$R")"
eq "V2 incremental reviewers get only the fix diff" "1" "$(grep -cE 'INCREMENTAL=true.*fix\.diff.*review only the changes' "$R")"
eq "V3 review.md no longer claims default 2" "0" "$(grep -c 'maxFixAttempts` (default 2)' "$R")"
eq "V4 review FAIL routes to the fix-step cap gate" "1" "$(grep -cF '**FAIL → Step 8** (its **Cap gate** bounds the loop).' "$R")"

eq "V5 old full-scope security wording is gone" "0" "$(grep -cF 'security-reviewer keeps full scope' "$R")"
eq "V10 incremental security-reviewer gets fix.diff + prior [SEC-N] by id" "1" "$(grep -cE 'security-reviewer gets the same fix\.diff path.*FIX_FILES.*prior `\[SEC-N\]` list from review-prev\.md.*re-report unfixed' "$R")"
eq "V11 parallel spawn scopes security-reviewer to fix.diff when incremental" "1" "$(grep -cF 'on `INCREMENTAL=true`: fix.diff + `$FIX_FILES`' "$R")"
eq "V6 CYCLE guarded as numeric (both sites)" "2" "$(grep -cF '[[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1' "$R")"
eq "V7 fix.md increments the counter before the developer dispatch (resume-safe)" "yes" "$(il=$(grep -n 'n1_increment_counter.*review_fix_cycle' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); sp=$(grep -n 'spawn developer' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); [ -n "$il" ] && [ "$il" -lt "$sp" ] && echo yes || echo no)"
eq "V8 cycle emit MAX has a source" "1" "$(grep -c 'echo "MAX=\$REVIEW_FIX_MAX"' skills/n1-start/steps/fix.md)"
eq "V9 incremental code-reviewer gets prior findings" "1" "$(grep -cF 'review-prev.md: re-report' "$R")"

# ---- wiring: PR body + telemetry ----
eq "P1 tech-writer renders For Human Review" "1" "$(grep -cE 'review\.md has `## For Human Review`.*mandatory' agents/tech-writer.md)"
eq "P2 pr.md emits review_unresolved_at_pr" "1" "$(grep -c '"review_unresolved_at_pr=' skills/n1-start/steps/pr.md)"

eq "R5 fix.md consults the gate before the counter increment (reverting the gate call goes red)" "yes" "$(gl=$(grep -n 'n1_review_fix_gate' "$F" | head -1 | cut -d: -f1); il=$(grep -n 'n1_increment_counter.*review_fix_cycle' "$F" | head -1 | cut -d: -f1); [ -n "$gl" ] && [ -n "$il" ] && [ "$gl" -lt "$il" ] && echo yes || echo no)"

# ---- audit (N1-260): counter past the cap needs one human-answered `fix` ledger row per extra cycle ----
ovl() { # <counter> [ledger rows...] -> overview.md with frontmatter + Decision Ledger
    ov "$1"; shift
    printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OV"
    [ $# -eq 0 ] || printf '%s\n' "$@" >> "$OV"
}
ASKED='| fix | quality | A | [asked] | review fix cap reached | One more FAIL fix cycle | List under For Human Review | user chose 2 | codebase |'
HL_ASKED='| fix | headless | A | [asked] | review fix cap reached | 2 | 1 | headless: ask-mode answer | --- |'
PLAN='| fix | headless | A | [plan] | review fix cap reached | 2 | 1 | queue plan pre-decision: extend | --- |'
AUTO_CAP='| fix | quality | A | [auto] | review fix cap reached | List under For Human Review | Prompt user | qualityEscalations=auto-accept | --- |'
AUTO_EXTRA='| fix | quality | A | [auto-decided] | review-fix-cap-extra | One more FAIL fix cycle | For Human Review | SEC-5 Medium open | --- |'
OTHER='| review | quality | A | [asked] | review tier | FULL | NARROW | user chose | codebase |'
cfg '{}'
ovl 0; eq "A1 counter 0 -> ok" "ok" "$(n1_review_fix_audit "$OV")"
ovl 1; eq "A2 counter at cap 1, no rows -> ok" "ok" "$(n1_review_fix_audit "$OV")"
ovl 2; eq "A3 counter 2 > cap 1, no rows -> breach" "breach" "$(n1_review_fix_audit "$OV")"
n1_review_fix_audit "$OV" >/dev/null; eq "A3b breach returns 1" "1" "$?"
ovl 2 "$ASKED"; eq "A4 interactive [asked] fix row covers one extra cycle" "ok" "$(n1_review_fix_audit "$OV")"
ovl 2 "$HL_ASKED"; eq "A5 headless ask-mode [asked] fix row counts" "ok" "$(n1_review_fix_audit "$OV")"
ovl 2 "$PLAN"; eq "A6 queue plan-time [plan] fix row counts" "ok" "$(n1_review_fix_audit "$OV")"
ovl 3 "$ASKED"; eq "A7 two extra cycles, one row -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 3 "$ASKED" "$HL_ASKED"; eq "A8 two extra cycles, two rows -> ok" "ok" "$(n1_review_fix_audit "$OV")"
ovl 2 "$OTHER"; eq "A9 [asked] row from another step does not count -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ov 2; eq "A10 legacy overview without ledger, above cap -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 2 '| fix | quality | A | [asked] | security escalation | Fix inline | Ask | user chose | codebase |'; eq "A11 unrelated fix-step [asked] row -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 2 '| fix | quality | A | [asked] | review fix cap reached | List under For Human Review | One more FAIL fix cycle | user chose 1 | codebase |'; eq "A11b cap ask answered option 1 -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 2 '| fix | headless | A | [asked] | review fix cap reached | 1 | 2 | headless: ask-mode answer | --- |'; eq "A11c headless ask-mode answer 1 -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ov 08; eq "A11e octal-looking counter 08 -> breach, no crash" "breach" "$(n1_review_fix_audit "$OV")"
ovl 08 "$ASKED"; eq "A11f counter 08 needs 7 rows -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ov abc; eq "A12 non-numeric counter -> breach (fail closed)" "breach" "$(n1_review_fix_audit "$OV")"
cfg '{"review":{"maxFixAttempts":2}}'
ovl 2; eq "A13 cap 2, counter 2 -> ok" "ok" "$(n1_review_fix_audit "$OV")"
ovl 3; eq "A14 cap 2, counter 3, no rows -> breach" "breach" "$(n1_review_fix_audit "$OV")"
cfg '{}'

# ---- regression (N1-241): hands-off Exhausted with an open SEC finding ----
cfg '{"autonomy":{"qualityEscalations":"auto-accept"}}'
ovl 2 "$AUTO_CAP" "$AUTO_EXTRA"
eq "X1 N1-241 state (cycle 2, cap 1): gate reads exhausted" "exhausted" "$(n1_review_fix_gate "$OV")"
eq "X2 N1-241 state: [auto]/[auto-decided] rows never authorize the extra cycle -> breach" "breach" "$(n1_review_fix_audit "$OV")"
cfg '{}'
eq "H1 auto-accept Exhausted branch excludes open SEC findings" "1" "$(grep -cE '^\*\*Exhausted\*\*.*`QE=auto-accept` and no open `\[SEC-N\]`' "$F")"
eq "H2 open SEC routes to the ask under any QE, never an [auto] row" "1" "$(grep -cE '^\*\*Exhausted\*\*.*security-class finding needs this ask under any `QE`; never an `\[auto\]` row' "$F")"
eq "H3a no (Recommended) on option 2 for SEC" "0" "$(grep -c 'Mark (Recommended) on 2' "$F")"
eq "H3b SEC option list carries the verbatim no-recommendation sentence" "1" "$(grep -cF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$F")"
eq "H4 headless SEC Exhausted goes through Headless Guard, never auto-extends" "1" "$(grep -cE '^\*\*Exhausted\*\*.*Headless Guard.*never auto-extend' "$F")"
eq "H5 rule: gate before every FAIL dispatch, no inline fixes, no extra developer" "1" "$(grep -cE '^\*\*Rule \(N1-260\):\*\* `n1_review_fix_gate` .*runs before every FAIL developer dispatch.*never fixes findings inline.*never dispatches a developer outside this step' "$F")"
AUDIT_LN=$(awk '/^[[:space:]]*```/{b=!b; next} b && /n1_review_fix_audit/{print NR; exit}' "$F")
eq "W7 fix.md runs the audit in a fence before the first developer spawn" "yes" "$([ -n "$AUDIT_LN" ] && [ -n "$SPAWN_LN" ] && [ "$AUDIT_LN" -lt "$SPAWN_LN" ] && echo yes || echo no)"
eq "W8 audit breach is listed under For Human Review as [FIX-CAP]" "1" "$(grep -cE '^\*\*Exhausted\*\*.*`FIX_AUDIT` other than `ok` \(including empty\).*\[FIX-CAP\].*## For Human Review' "$F")"
PIN=$(grep -oE '`\| fix \| quality \| A \| \[asked\] \| review fix cap reached \| One more FAIL fix cycle \|`' "$F" | head -1 | tr -d '`')
ovl 2 "$PIN a | r | codebase |"
eq "W9 the option-2 ledger row fix.md prescribes satisfies the audit" "ok" "$(n1_review_fix_audit "$OV")"

PRF=skills/n1-start/steps/pr.md
PA_LN=$(awk '/^[[:space:]]*```/{b=!b; next} b && /n1_review_fix_audit/{print NR; exit}' "$PRF")
PR_LN=$(grep -n 'n1:n1-pr`. Pass:' "$PRF" | head -1 | cut -d: -f1)
eq "P3 pr.md audits the fix cap in a fence before n1-pr runs" "yes" "$([ -n "$PA_LN" ] && [ -n "$PR_LN" ] && [ "$PA_LN" -lt "$PR_LN" ] && echo yes || echo no)"
eq "P4 pr.md breach surfaces [FIX-CAP] under For Human Review, never as an [auto] pass" "1" "$(grep -cE '^`FIX_AUDIT` other than `ok`, including empty.*\[FIX-CAP\].*## For Human Review.*never an `\[auto\]`' "$PRF")"

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
