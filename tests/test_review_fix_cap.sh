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
source lib/fingerprints.sh

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
RI=skills/n1-start/procedures/review-incremental.md
eq "V1 re-review is incremental from cycle 1 on the fix diff" "1" "$(grep -cF '[ "$CYCLE" -ge 1 ] && [ -s "$N1_HOME/memory/$ID/fix.diff" ]' "$R")"
eq "V2 incremental reviewers get only the fix diff" "1" "$(grep -cE 'INCREMENTAL=true.*fix\.diff.*review only the changes' "$RI")"
eq "V3 review.md no longer claims default 2" "0" "$(grep -c 'maxFixAttempts` (default 2)' "$R")"
eq "V4 review FAIL routes to the fix-step cap gate" "1" "$(grep -cF '**FAIL → Step 8** (its **Cap gate** bounds the loop).' "$R")"

eq "V5 old full-scope security wording is gone" "0" "$(grep -cF 'security-reviewer keeps full scope' "$R")"
eq "V10 incremental security-reviewer gets fix.diff + prior [SEC-N] by id" "1" "$(grep -cE 'security-reviewer gets the same fix\.diff path.*FIX_FILES.*prior `\[SEC-N\]` list from review-prev\.md.*re-report unfixed' "$RI")"
eq "V11 parallel spawn scopes security-reviewer to fix.diff when incremental" "1" "$(grep -cF 'on `INCREMENTAL=true`: fix.diff + `$FIX_FILES`' "$R")"
eq "V6 CYCLE guarded as numeric (both sites)" "2" "$(grep -cF '[[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1' "$R")"
eq "V7 fix.md increments the counter before the developer dispatch (resume-safe)" "yes" "$(il=$(grep -n 'n1_increment_counter.*review_fix_cycle' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); sp=$(grep -n 'spawn developer' skills/n1-start/steps/fix.md | head -1 | cut -d: -f1); [ -n "$il" ] && [ "$il" -lt "$sp" ] && echo yes || echo no)"
eq "V8 cycle emit MAX has a source" "1" "$(grep -c 'echo "MAX=\$REVIEW_FIX_MAX"' skills/n1-start/steps/fix.md)"
eq "V9 incremental code-reviewer gets prior findings" "1" "$(grep -cF 'review-prev.md: re-report' "$RI")"

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
ov 18446744073709551616; eq "A12b 2^64 counter wraps at 64 bits -> breach (fail closed)" "breach" "$(n1_review_fix_audit "$OV")"
ovl 2 "$ASKED"; printf '%s' "$(cat "$OV")" > "$OV"  # drop the final newline
eq "A12c extension row at EOF without trailing newline counts" "ok" "$(n1_review_fix_audit "$OV")"
cfg '{"review":{"maxFixAttempts":18446744073709551616}}'
ovl 2; eq "A12d overflowing cap falls back to default -> breach" "breach" "$(n1_review_fix_audit "$OV")"
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
eq "H1 auto-accept Exhausted branch excludes open SEC findings" "1" "$(grep -cE '^\*\*Exhausted\*\*.*`QE=auto-accept` and no open in-diff non-Low `\[SEC-N\]`' "$F")"
eq "H2 open SEC routes to the ask under any QE, never an [auto] row" "1" "$(grep -cE '^\*\*Exhausted\*\*.*security-class finding needs this ask under any `QE`; never an `\[auto\]` row' "$F")"
eq "H3a no (Recommended) on option 2 for SEC" "0" "$(grep -c 'Mark (Recommended) on 2' "$F")"
eq "H3b N1-259 wins: no SEC no-recommendation override, option 1 always recommended" "0" "$(grep -cF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$F")"
eq "H4 Exhausted runs § Grant first (every mode); the Headless Guard path still never auto-extends" "1" "$(grep -cE '^\*\*Exhausted\*\* \(FAIL\): `procedures/review-extra-round\.md § Grant` first; `granted` skips the rest\. `QE=auto-accept` and no open.*Headless Guard.*never auto-extend' "$F")"
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

# ---- recurrence (N1-345 D2/D16): eligible fingerprint in buckets N and N-1 ----
FPJ="$T/fp.jsonl"; DIFF="$T/fix.diff"
fpj() { # <"id severity cycle fp">... -> fresh fingerprints.jsonl
    : > "$FPJ"; local r id sev cyc fp
    for r in "$@"; do read -r id sev cyc fp <<< "$r"; n1_fingerprint_append "$FPJ" "$fp" "$id" "$sev" active "$cyc"; done
}
fpj "CR-1 High 0 fa" "CR-1 High 1 fa"; n1_fingerprint_recurred "$FPJ" 1
eq "F1 High fingerprint in buckets 0 and 1 -> recurred" "0" "$?"
fpj "CR-1 High 0 fa" "CR-2 High 1 fb"; n1_fingerprint_recurred "$FPJ" 1
eq "F2 different fingerprints -> not recurred" "1" "$?"
fpj "CR-1 High 2 fz" "CR-1 High 12 fz"; n1_fingerprint_recurred "$FPJ" 2
eq "F3 bucket match is anchored (cycle 12 is not cycle 1)" "1" "$?"
fpj "SEC-1 Low 0 fl" "SEC-1 Low 1 fl" "CR-2 High 1 fb"; n1_fingerprint_recurred "$FPJ" 1
eq "F4 a recurring Low [SEC-N] is not an eligible recurrence" "1" "$?"
fpj "SEC-1 Medium 0 fs" "SEC-1 Medium 1 fs"; n1_fingerprint_recurred "$FPJ" 1
eq "F5 recurring Medium [SEC-N] -> recurred" "0" "$?"
n1_fingerprint_recurred "$T/missing.jsonl" 1
eq "F6 missing jsonl -> not recurred" "1" "$?"

# ---- extra-round out-of-scope filter (N1-345 D20) ----
FX="$T/fix-changed-files"; PREV="$T/review-prev.md"; IDX="$T/review-index.md"
: > "$FPJ"
n1_fingerprint_append "$FPJ" "$(n1_fingerprint_finding lib/old.sh 'old bug')" CR-1 High active 1
n1_fingerprint_append "$FPJ" "$(n1_fingerprint_finding lib/recur.sh 'recurring title')" CR-9 High active 1
printf 'lib/fixed.sh\n' > "$FX"
printf '### Verdict: FAIL\n- [CR-1] High lib/old.sh:10 — old bug\n' > "$PREV"
mkidx() { cat > "$IDX" <<'EOF'
Index:
- [CR-1] High lib/old.sh:10 — old bug
- [CR-2] High lib/fixed.sh:5 — new in a fixed file
- [CR-3] High lib/other.sh:7 — unrelated new
- [SEC-1] Medium ./Lib/Other.sh:9 — new sec
- [RULE-1] Low docs/x.md:1 — new rule
- [CR-4] High lib/recur.sh:3 — recurring title
- [CR-5] High ./LIB/Fixed.sh:8 — case-different fixed file
- [CR-6] High no-colon-here — unparsable location
EOF
}
ids() { sed -n 's/^- \[\([A-Z]*-[0-9]*\)\].*/\1/p' | tr '\n' ' ' | sed 's/ $//'; }
mkidx; OUT=$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX")
eq "FL1 new non-SEC findings outside the fix files are filtered (any severity, incl. RULE)" "CR-3 RULE-1" "$(ids <<< "$OUT")"
eq "FL2 filtered lines print verbatim (For Human Review format)" "- [CR-3] High lib/other.sh:7 — unrelated new" "$(head -1 <<< "$OUT")"
eq "FL3 kept: prev id+file, SEC, fixed file, N-1 fingerprint (same parse as fp-new.tsv), case-different fixed file, unparsable" "CR-1 CR-2 SEC-1 CR-4 CR-5 CR-6" "$(ids < "$IDX")"
eq "FL4 non-Index lines are kept" "1" "$(grep -cx 'Index:' "$IDX")"
mkidx; cp "$IDX" "$T/idx.before"
rm -f "$FX"; eq "FL5 missing fix-changed-files -> nothing filtered" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX")"
eq "FL5b index untouched" "same" "$(cmp -s "$IDX" "$T/idx.before" && echo same || echo changed)"
: > "$FX"; eq "FL6 empty fix-changed-files -> nothing filtered" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX")"
printf 'lib/fixed.sh\n' > "$FX"
eq "FL7 missing review-prev.md -> nothing filtered" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$T/nope.md" "$IDX")"
eq "FL8 cycle 0 -> nothing filtered" "" "$(n1_fingerprint_filter_oos "$FPJ" 0 "$FX" "$PREV" "$IDX")"
eq "FL8b index still untouched" "same" "$(cmp -s "$IDX" "$T/idx.before" && echo same || echo changed)"

# ID reuse (CR-1): fixed [CR-2] in another file must not shield a new [CR-2] in an unchanged file
printf -- '- [CR-2] High lib/old.sh:10 — old bug\n' > "$PREV"
printf 'Index:\n- [CR-2] High lib/other.sh:7 — brand new\n' > "$IDX"
eq "FL9 reused id in another unchanged file is filtered" "CR-2" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
printf 'Index:\n- [CR-2] High lib/old.sh:12 — same finding moved\n' > "$IDX"
eq "FL9b same id and same file stays" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
# SEC-1: security findings never filtered
printf 'Index:\n- [SEC-9] Critical untouched.sh:1 — x\n' > "$IDX"
eq "FL10 new [SEC-N] stays in the index" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
eq "FL10b index keeps SEC line" "SEC-9" "$(ids < "$IDX")"
# SEC-2: location shapes that are not one repo-relative path stay
for loc in '/abs/untouched.sh:1' 'a/untouched.sh:1' 'b/untouched.sh:1' 'untouched.sh:1, lib/y.sh:2' 'my file.sh:1' 'x.sh:1:2'; do
    printf 'Index:\n- [CR-7] High %s — odd\n' "$loc" > "$IDX"
    eq "FL11 location '$loc' stays" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
done
printf 'Index:\n- [CR-7] High untouched.sh:1 — plain\n' > "$IDX"
eq "FL11b plain repo path is filtered" "CR-7" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
# Security-class title under a CR id stays; plain title still filtered
printf 'Index:\n- [CR-8] High untouched.sh:1 — SQL Injection in lookup\n- [CR-9] High untouched.sh:2 — Missing AuthZ check\n' > "$IDX"
eq "FL12 security-class title under a CR id stays" "" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
eq "FL12b both lines kept in the index" "CR-8 CR-9" "$(ids < "$IDX")"
printf 'Index:\n- [CR-8] High untouched.sh:1 — Rename helper for clarity\n' > "$IDX"
eq "FL12c plain title is still filtered" "CR-8" "$(n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" | ids)"
# Write failure keeps the original index and fails
printf 'Index:\n- [CR-8] High untouched.sh:1 — Rename helper for clarity\n' > "$IDX"; cp "$IDX" "$T/idx.before"
( trap '' XFSZ; ulimit -f 0; n1_fingerprint_filter_oos "$FPJ" 2 "$FX" "$PREV" "$IDX" >/dev/null 2>&1 ); WRC=$?
eq "FL13 failed temp write returns non-zero" "1" "$([ "$WRC" -ne 0 ] && echo 1 || echo 0)"
eq "FL13b original index preserved" "same" "$(cmp -s "$IDX" "$T/idx.before" && echo same || echo changed)"
eq "FL13c no temp file left" "0" "$(ls "$IDX".* 2>/dev/null | wc -l | tr -d ' ')"

# ---- extra round grant (N1-345): one automatic extra FAIL cycle at the cap ----
cfg '{}'
GRANTED='| fix | quality | A | [granted] | review fix cap reached | auto extra round | ask the user | new High/SEC finding, blocking count dropped, fix changed code | --- |'
grant() { n1_review_fix_grant "$OV" "$FPJ" "$DIFF"; }
printf 'diff --git a/x b/x\n' > "$DIFF"
fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-3 High 1 fc"
ovl 1; eq "G1 cap reached, new High, count 2->1, non-empty diff -> granted" "granted" "$(grant)"
eq "G1b exactly one [granted] row, equal to the documented row" "1" "$(grep -cxF "$GRANTED" "$OV")"
n1_increment_counter "$OV" review_fix_cycle >/dev/null
eq "G1c extra round (cur = max+1, one [granted]) -> audit ok" "ok" "$(n1_review_fix_audit "$OV")"
eq "G1d extra-round trigger is true" "true" "$(n1_review_fix_extra_round "$OV")"
eq "G1e second cap-reached state -> deny (asks; no third automatic round)" "deny:not-at-cap" "$(grant)"
eq "G1f still one [granted] row" "1" "$(grep -cF '[granted]' "$OV")"
ovl 1; fpj "CR-1 High 0 fa" "CR-3 High 1 fc"
eq "G2 1-vs-1 High tie is NON_CONVERGING -> deny" "deny:non-converging" "$(grant)"
eq "G2b deny writes no ledger row" "0" "$(grep -cF '[granted]' "$OV")"
ovl 1; fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-3 High 1 fc"; printf 'not json\n' >> "$FPJ"
if command -v jq >/dev/null 2>&1; then eq "G3b unparsable fingerprints.jsonl line -> deny" "deny:fingerprints" "$(grant)"; fi
ovl 1; fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-1 High 1 fa"
eq "G3 High fingerprint in both of the last two reviews -> deny" "deny:recurred" "$(grant)"
ovl 1; fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-3 High 1 fc"; : > "$DIFF"
eq "G4 empty fix.diff -> deny" "deny:empty-diff" "$(grant)"
rm -f "$DIFF"; eq "G4b missing fix.diff -> deny" "deny:empty-diff" "$(grant)"
printf 'diff --git a/x b/x\n' > "$DIFF"
ovl 1; fpj "CR-1 High 0 fa" "CR-2 Medium 1 fm" "SEC-1 Low 1 fl"; cp "$OV" "$T/ov.before"
eq "G5 only Medium non-SEC / Low SEC open -> deny, exactly as today" "deny:no-eligible" "$(grant)"
eq "G5b overview untouched on deny" "same" "$(cmp -s "$OV" "$T/ov.before" && echo same || echo changed)"
ovl 1; fpj "CR-1 High 0 fa" "SEC-2 Medium 1 fs"
eq "G6 only a new Medium [SEC-N] open (count 0 converges) -> granted" "granted" "$(grant)"
fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-3 High 1 fc"
ovl 1 "$GRANTED"; eq "G7 [granted] row already in the ledger -> deny" "deny:extended" "$(grant)"
ovl 1 "$ASKED"; eq "G7b cap ask already in the ledger -> deny" "deny:extended" "$(grant)"
ovl 0; eq "G8 below the cap -> deny" "deny:not-at-cap" "$(grant)"
ov abc; eq "G8b garbage counter -> deny" "deny:counter" "$(grant)"
cfg '{"review":{"maxFixAttempts":2}}'; ovl 3 "$ASKED"
eq "G8c user-extended past cap 2 -> deny" "deny:not-at-cap" "$(grant)"
cfg '{}'
ovl 1; rm -f "$FPJ"; eq "G9 missing fingerprints.jsonl -> deny" "deny:no-eligible" "$(grant)"
fpj "CR-1 High 0 fa" "CR-2 High 0 fb" "CR-3 High 1 fc"
ov 1; eq "G10 no Decision Ledger section -> granted, section created" "granted" "$(grant)"
n1_increment_counter "$OV" review_fix_cycle >/dev/null
eq "G10b created section satisfies the audit" "ok" "$(n1_review_fix_audit "$OV")"

# ---- audit counting (N1-345 D15): n = [asked]/[plan] rows + min([granted] rows, 1) ----
ovl 2 "$GRANTED"; eq "A15 one [granted] row covers the one extra cycle" "ok" "$(n1_review_fix_audit "$OV")"
ovl 3 "$GRANTED" "$GRANTED"; eq "A16 two [granted] rows, no [asked] -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 3 "$GRANTED" "$ASKED"; eq "A17 [granted] plus an [asked] option 2 covers two extra cycles" "ok" "$(n1_review_fix_audit "$OV")"
ov 2; printf '\n## Notes\n\n%s\n' "$GRANTED" >> "$OV"
eq "A18 [granted] row outside the Decision Ledger -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 2 '| fix | quality | A | [granted] | review fix cap reached | One more FAIL fix cycle | ask | x | --- |'
eq "A19 [granted] with another Chosen text -> breach" "breach" "$(n1_review_fix_audit "$OV")"

# ---- extra-round trigger ----
ovl 2 "$GRANTED"; eq "E1 cur = max+1 with one [granted] -> true" "true" "$(n1_review_fix_extra_round "$OV")"
ovl 1 "$GRANTED"; eq "E2 at the cap -> false" "false" "$(n1_review_fix_extra_round "$OV")"
ovl 2 "$ASKED"; eq "E3 user extension, no [granted] -> false" "false" "$(n1_review_fix_extra_round "$OV")"
ovl 3 "$GRANTED" "$ASKED"; eq "E4 past the extra round -> false" "false" "$(n1_review_fix_extra_round "$OV")"

# ---- wiring: extra round (N1-345) ----
XP=skills/n1-start/procedures/review-extra-round.md
eq "XW1 Rule counts one [granted] row as a cap extension" "1" "$(grep -cF 'or one `[granted]` row raises `review_fix_cycle` past the cap' "$F")"
eq "XW2 Exhausted For Human Review write merges (keeps filtered entries)" "1" "$(grep -cE '^\*\*Exhausted\*\*.*## For Human Review` to review\.md \(file-write; merge if present\)' "$F")"
eq "XW3 Exhausted no longer replaces For Human Review" "0" "$(grep -cE '^\*\*Exhausted\*\*.*replace if present' "$F")"
FILT_LN=$(grep -n 'procedures/review-extra-round.md § Filter' "$R" | head -1 | cut -d: -f1)
FPNEW_LN=$(grep -n 'fp-new.tsv` with the file-write mechanism' "$R" | head -1 | cut -d: -f1)
eq "XW4 review.md reaches § Filter before writing fp-new.tsv" "yes" "$([ -n "$FILT_LN" ] && [ -n "$FPNEW_LN" ] && [ "$FILT_LN" -le "$FPNEW_LN" ] && echo yes || echo no)"
eq "XW5 grant fence passes the three memory paths to the helper" "1" "$(grep -cF 'FIX_GRANT=$(n1_review_fix_grant "$MEM/overview.md" "$MEM/fingerprints.jsonl" "$MEM/fix.diff")' "$XP")"
eq "XW6 both helper fences source fingerprints.sh" "2" "$(grep -cF 'source "$N1_ROOT/lib/fingerprints.sh"' "$XP")"
eq "XW7 the model never writes the [granted] row" "1" "$(grep -cF 'never write it yourself' "$XP")"
eq "XW8 filter call over the orchestrator-written index file" "1" "$(grep -cF 'n1_fingerprint_filter_oos "$MEM/fingerprints.jsonl" "$CYCLE" "$MEM/fix-changed-files" "$MEM/review-prev.md" "$MEM/review-index.md" > "$MEM/review-oos.md"' "$XP")"
eq "XW9 filter runs before fp-new.tsv, NON_CONVERGING and the verdict" "1" "$(grep -cF 'never enter `fp-new.tsv`, NON_CONVERGING or the verdict' "$XP")"
eq "XW10 filtered lines are appended to For Human Review by a fixed command" "1" "$(grep -cF 'cat "$MEM/review-oos.md"; } >> "$MEM/review.md"' "$XP")"
eq "XW11 Grant runs in every mode, headless and queue included" "1" "$(grep -cF 'in every mode, headless and queue included' "$XP")"

# ---- docs (N1-345) ----
ARCH=references/architecture.md
eq "DOC1 architecture.md has a Review Fix Cap section" "1" "$(grep -cx '## Review Fix Cap' "$ARCH")"
eq "DOC2 section documents NON_CONVERGING, the tie, the grant, the [granted] row and the filter" "5" "$(sed -n '/^## Review Fix Cap$/,/^## Codex Review$/p' "$ARCH" | grep -cE '^\*\*(NON_CONVERGING|Reach \(D13\)|One automatic extra round|`\[granted\]` row|Extra-round filter)')"
eq "DOC3 architecture row text equals the helper row" "1" "$(grep -cF '| fix | quality | A | [granted] | review fix cap reached | auto extra round | ask the user |' "$ARCH")"
eq "DOC4 tech-writer orders [granted] between [auto] and [asked]" "1" "$(grep -cF '`[auto]` before `[granted]` before `[asked]` within a tier' agents/tech-writer.md)"
eq "DOC5 n1-review no longer claims a fixed maximum of 2" "0" "$(grep -c 'Maximum 2 review-fix cycles' skills/n1-review/steps/01-analyze.md)"

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
