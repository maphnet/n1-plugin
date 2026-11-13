#!/usr/bin/env bash
# tests/test_review_fix_budget.sh -- N1-569: progress-gated review fix budget, per-finding states,
# developer contract and fix outcome telemetry.
# Run: bash tests/test_review_fix_budget.sh   (clean: env -i PATH=/usr/local/bin:/usr/bin:/bin bash tests/test_review_fix_budget.sh)
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
M="$T/mem"; mkdir -p "$M"

# ---- blocking set (D7) ----
cat > "$T/r.md" <<'EOF'
### Verdict: FAIL
- [CR-1] High lib/a.sh:10 — null deref
- [CR-2] Medium lib/b.sh:3 — wrong default
- [TQ-1] Medium tests/t.sh:1 — hollow test
- [CR-3] Low lib/c.sh:1 — naming
- [SEC-1] Medium lib/d.sh:7 — token logged
- [SEC-2] Low lib/d.sh:9 — verbose error
- [SEC-3] High lib/e.sh:2 — old injection (pre-existing)
- [RULE-1] Low docs/x.md:4 — missing recommended label
- [CX-1] Medium lib/f.sh:5 — unquoted path (security)
- [CR-1] High lib/a.sh:10 — null deref
EOF
ids() { cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
eq "B1 blocking set: Critical/High, non-TQ Medium, non-Low SEC, any RULE, security CX; deduped" "CR-1 CR-2 SEC-1 RULE-1 CX-1" "$(n1_review_blocking_ids "$T/r.md" | ids)"
eq "B2 row is id, severity, file, title" "CR-1|High|lib/a.sh|null deref" "$(n1_review_blocking_ids "$T/r.md" | head -1 | tr '\t' '|')"
eq "B3 unreadable file returns 1" "1" "$(n1_review_blocking_ids "$T/none.md" >/dev/null; echo $?)"

# ---- open statuses and age (D9) ----
FPJ="$M/fingerprints.jsonl"; : > "$FPJ"
n1_fingerprint_append "$FPJ" fa CR-1 High active 1
n1_fingerprint_append "$FPJ" fb CR-2 High carried 1 1
n1_fingerprint_append "$FPJ" fc CR-3 High new 1 0
n1_fingerprint_append "$FPJ" fd CR-4 High resolved 1 0
eq "S1 carried/new rows count as open, resolved does not" "3" "$(n1_fingerprint_blocking_count_for_cycle "$FPJ" 1)"
eq "S2 age is written right after cycle" "1" "$(grep -c '"status":"carried","cycle":1,"age":1,"ts"' "$FPJ")"
n1_fingerprint_append "$FPJ" fa CR-1 High resolved 1 0
eq "S3 a later resolved row closes the same fingerprint" "2" "$(n1_fingerprint_blocking_count_for_cycle "$FPJ" 1)"
eq "S4 rows without age keep the old shape" "1" "$(grep -c '"status":"active","cycle":1,"ts"' "$FPJ")"

# ---- per-finding states (D3, D4) ----
st_setup() { # <prev Index lines> <new Index lines> [status lines]
    printf '### Verdict: FAIL\n%s\n' "$1" > "$M/review-prev.md"
    printf '### Verdict: FAIL\n%s\n' "$2" > "$M/review.md"
    if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$M/review-status.md"; else rm -f "$M/review-status.md"; fi
    : > "$M/fingerprints.jsonl"
}
rows() { grep "\"cycle\":$1," "$M/fingerprints.jsonl" | sed -n 's/.*"id":"\([^"]*\)".*"status":"\([^"]*\)","cycle":[0-9]*,"age":\([0-9]*\).*/\1:\2:\3/p' | tr '\n' ' ' | sed 's/ $//'; }

st_setup '- [CR-1] High lib/a.sh:10 — null deref' '- [CR-1] High lib/a.sh:12 — null pointer dereference on empty input'
eq "ST1 re-titled finding, no status line: same ID + same file -> carried" "resolved=0 carried=1 new=0 unlabeled=1" "$(n1_fix_states "$M" 1)"
eq "ST1b carried row with age 1" "CR-1:carried:1" "$(rows 1)"
st_setup '- [CR-1] High lib/a.sh:10 — null deref' '- [CR-4] High lib/a.sh:12 — null pointer dereference' '- [CR-1] OPEN as [CR-4]'
eq "ST2 re-numbered and re-titled via OPEN as -> carried, not new" "resolved=0 carried=1 new=0 unlabeled=0" "$(n1_fix_states "$M" 1)"
eq "ST2b carried under the new ID" "CR-4:carried:1" "$(rows 1)"
st_setup '- [CR-1] High lib/a.sh:10 — null deref' '- [CR-7] High lib/a.sh:10 — null deref'
eq "ST3 re-numbered, no status line: same fingerprint -> carried" "CR-7:carried:1" "$(n1_fix_states "$M" 1 >/dev/null; rows 1)"
st_setup $'- [CR-1] High lib/a.sh:1 — one\n- [CR-2] High lib/b.sh:2 — two' $'- [CR-1] High lib/a.sh:1 — one\n- [CR-3] High lib/c.sh:3 — three' $'- [CR-1] OPEN\n- [CR-2] FIXED'
eq "ST4 2 High -> 2 High with one resolved and one new" "resolved=1 carried=1 new=1 unlabeled=0" "$(n1_fix_states "$M" 1)"
eq "ST4b rows: resolved CR-2, carried CR-1, new CR-3" "CR-1:carried:1 CR-2:resolved:0 CR-3:new:0" "$(rows 1)"
st_setup '- [CR-1] High lib/a.sh:1 — one' '- [CR-1] High lib/a.sh:4 — one' '- [CR-1] FIXED'
eq "ST5 FIXED contradicted by the new Index (same ID, same file) -> carried" "resolved=0 carried=1 new=0 unlabeled=0" "$(n1_fix_states "$M" 1)"
st_setup $'- [SEC-1] Medium lib/d.sh:7 — token logged\n- [CR-2] High lib/b.sh:3 — wrong default\n- [CR-3] High lib/c.sh:1 — slow loop' \
    '- [CR-3] Low lib/c.sh:1 — slow loop' $'- [SEC-1] WITHDRAWN\n- [CR-2] OOS\n- [CR-3] DOWNGRADED'
eq "ST6 dispute rulings withdrawn/oos/downgraded leave the blocking set" "resolved=3 carried=0 new=0 unlabeled=0" "$(n1_fix_states "$M" 1)"
eq "ST6b rows keep the ruling" "SEC-1:withdrawn:0 CR-2:oos:0 CR-3:downgraded:0" "$(rows 1)"
st_setup '- [SEC-1] Medium lib/d.sh:7 — token logged' '- [SEC-1] Medium lib/d.sh:7 — token logged' '- [SEC-1] OPEN'
eq "ST7 dispute ruled stands (OPEN) stays blocking" "SEC-1:carried:1" "$(n1_fix_states "$M" 1 >/dev/null; rows 1)"
st_setup '- [CR-4] High lib/a.sh:12 — x' '- [CR-4] High lib/a.sh:12 — x'
n1_fingerprint_append "$M/fingerprints.jsonl" fz CR-4 High carried 1 1
eq "ST8 age follows the lineage across cycles" "CR-4:carried:2" "$(n1_fix_states "$M" 2 >/dev/null; rows 2)"
eq "ST9 cycle 0 -> rc 1, no output" "1:" "$(o=$(n1_fix_states "$M" 0); echo "$?:$o")"
rm -f "$M/review-prev.md"; eq "ST9b missing review-prev.md -> rc 1" "1" "$(n1_fix_states "$M" 1 >/dev/null; echo $?)"
printf '### Verdict: FAIL\n- [CR-1] High lib/a.sh:1 — %s\n' '$(touch '"$T"'/pwned)' > "$M/review-prev.md"; cp "$M/review-prev.md" "$M/review.md"; rm -f "$M/review-status.md"
n1_fix_states "$M" 1 >/dev/null
eq "ST10 reviewer title is data, never executed" "no" "$([ -e "$T/pwned" ] && echo yes || echo no)"

# ---- fix cycle 1 review findings (CR-2, CX-1, SEC-1) ----
st_setup $'- [CR-1] High lib/a.sh:1 — old defect\n- [CR-2] High lib/b.sh:2 — two' $'- [CR-1] High lib/a.sh:9 — brand new regression\n- [CR-2] High lib/b.sh:2 — two' $'- [CR-1] FIXED\n- [CR-2] OPEN'
eq "ST11 FIXED + reused ID with a different title in the same file -> resolved + new" "resolved=1 carried=1 new=1 unlabeled=0" "$(n1_fix_states "$M" 1)"
st_setup $'- [CR-1] High lib/a.sh:1 — one' $'- [CR-2] High lib/c.sh:1 — two\n\n## For Human Review\n\n- [CR-1] High lib/a.sh:1 — one' '- [CR-1] OOS'
eq "ST12 an OOS finding listed under For Human Review is not blocking" "resolved=1 carried=0 new=1 unlabeled=0" "$(n1_fix_states "$M" 1)"
printf '### Verdict: FAIL\n- [CR-1] High a.sh:1 — x\n\n## For Human Review\n- [CR-2] High b.sh:1 — y\n' > "$T/hr.md"
eq "B4 blocking set stops at ## For Human Review" "CR-1" "$(n1_review_blocking_ids "$T/hr.md" | ids)"
st_setup '- [SEC-1] High a.sh:1 — x' $'- [SEC-1] x","status":"resolved","cycle":9,"z":" a.sh:1 — t'
n1_fix_states "$M" 1 >/dev/null
eq "ST13 a forged severity token never lands in a state row" "0" "$(grep -c '"cycle":9,' "$M/fingerprints.jsonl")"

# ---- progress gate (D1, D6, D7, D9) ----
OV="$M/overview.md"; GJ="$M/fix-gate.jsonl"
cfg() { printf '%s\n' "$1" > "$N1_HOME/config.json"; }
ov() { printf -- '---\nstep: fix\nreview_fix_cycle: %s\n---\n' "$1" > "$OV"; }
gate() { n1_review_fix_gate "$OV"; }
last() { tail -n 1 "$GJ"; }
reason() { last | sed 's/.*"reason":"\([a-z-]*\)".*/\1/'; }
row() { n1_fingerprint_append "$M/fingerprints.jsonl" "f$1$3" "$1" High "$2" "$3" "${4:-0}"; }
cfg '{}'; rm -f "$M/review.md" "$M/review-prev.md" "$M/review-status.md" "$GJ"; : > "$M/fingerprints.jsonl"
ov 0; eq "G1 cycle 1 always allowed" "allow" "$(gate)"
eq "G1b decision logged" '{"cycle":1,"decision":"allow","reason":"first"}' "$(last)"
ov 1; eq "G2 no state rows for bucket 1 -> exhausted" "exhausted" "$(gate)"
eq "G2b deny reason no-data" '{"cycle":2,"decision":"deny","reason":"no-data"}' "$(last)"
gate >/dev/null; eq "G2c exhausted returns 1" "1" "$?"
row CR-1 resolved 1; row CR-3 new 1
eq "G3 bucket 1 resolved one -> cycle 2 allowed" "allow" "$(gate)"
eq "G3b reason progress" '{"cycle":2,"decision":"allow","reason":"progress"}' "$(last)"
ov 2; row CR-3 carried 2 1; row CR-5 resolved 2
eq "G4 bucket 2 resolved one, carried age 1 -> cycle 3 allowed" "allow" "$(gate)"
ov 3; eq "G5 default budget 3 spent -> cap" "exhausted|cap" "$(gate)|$(reason)"
: > "$M/fingerprints.jsonl"; ov 1; row CR-1 carried 1 1; row CR-2 new 1
eq "G6 a cycle that resolved nothing -> no-progress" "exhausted|no-progress" "$(gate)|$(reason)"
: > "$M/fingerprints.jsonl"; ov 2; row CR-1 carried 2 2; row CR-2 resolved 2
eq "G7 a finding open after two cycles stops the loop despite progress" "exhausted|carried" "$(gate)|$(reason)"
: > "$M/fingerprints.jsonl"; ov 1; row CR-1 resolved 1; printf '{"cycle":1,"contract":"missing"}\n' >> "$GJ"
eq "G8 developer contract missed twice in cycle 1 -> contract" "exhausted|contract" "$(gate)|$(reason)"
rm -f "$GJ"; : > "$M/fingerprints.jsonl"; row CR-1 resolved 1
cfg '{"review":{"maxFixAttempts":20}}'; ov 12
eq "G9 bucket match is anchored (bucket 1 is not bucket 12)" "exhausted|no-data" "$(gate)|$(reason)"
cfg '{"review":{"maxFixAttempts":1}}'; ov 1
eq "G10 configured value stays the upper bound" "exhausted|cap" "$(gate)|$(reason)"
cfg '{}'; ov abc; eq "G11 garbage counter fails closed" "exhausted|counter" "$(gate)|$(reason)"
printf 'not json\n' > "$M/fingerprints.jsonl"; ov 1
eq "G12 garbled fingerprints.jsonl -> no-data" "exhausted|no-data" "$(gate)|$(reason)"
rm -f "$GJ"; printf '### Verdict: PASS\n' > "$M/review.md"; ov 0; gate >/dev/null
eq "G13 PASS-routed (SOFT-ONLY) gate call logs nothing" "no" "$([ -e "$GJ" ] && echo yes || echo no)"
rm -f "$M/review.md"
eq "G14 grant helpers are gone from lib" "0" "$(cat lib/config.sh lib/fingerprints.sh | grep -cE '^(n1_review_fix_grant|n1_review_fix_extra_round|n1_fingerprint_recurred|_n1_fp_eligible_rows)\(\)')"

# ---- end to end: progress run gets cycles 2 and 3 with no ask; carried / no-progress runs stop (AC1, AC2) ----
step() { # <prev Index> <new Index> <status lines>: one gated FAIL cycle, then the re-review states
    gate >/dev/null || { echo stop; return; }
    n1_increment_counter "$OV" review_fix_cycle >/dev/null
    printf '### Verdict: FAIL\n%s\n' "$1" > "$M/review-prev.md"; printf '### Verdict: FAIL\n%s\n' "$2" > "$M/review.md"
    printf '%s\n' "$3" > "$M/review-status.md"
    n1_fix_states "$M" "$(n1_read_frontmatter "$OV" review_fix_cycle)" >/dev/null; echo ok
}
P1=$'- [CR-1] High lib/a.sh:1 — a\n- [SEC-1] Medium lib/b.sh:2 — token logged'
R1=$'- [SEC-1] Medium lib/b.sh:2 — token logged\n- [CR-2] High lib/c.sh:3 — c'
R2='- [CR-2] High lib/c.sh:3 — c'
cfg '{}'; rm -f "$GJ" "$M/review.md"; : > "$M/fingerprints.jsonl"; ov 0
OUT="$(step "$P1" "$R1" $'- [CR-1] FIXED\n- [SEC-1] OPEN') $(step "$R1" "$R2" $'- [SEC-1] FIXED\n- [CR-2] OPEN') $(step "$R2" "" '- [CR-2] FIXED') $(step "" "" "")"
eq "E1 progress run: cycles 1-3 run with no ask, then the budget stops it" "ok ok ok stop" "$OUT"
eq "E1b gate log reasons" "first progress progress cap" "$(sed 's/.*"reason":"\([a-z-]*\)".*/\1/' "$GJ" | tr '\n' ' ' | sed 's/ $//')"
A=$'- [CR-1] High lib/a.sh:1 — a\n- [CR-2] High lib/b.sh:1 — b'
B=$'- [CR-1] High lib/a.sh:1 — a\n- [CR-3] High lib/c.sh:1 — c'
C='- [CR-1] High lib/a.sh:1 — a'
rm -f "$GJ" "$M/review.md"; : > "$M/fingerprints.jsonl"; ov 0
OUT="$(step "$A" "$B" $'- [CR-1] OPEN\n- [CR-2] FIXED') $(step "$B" "$C" $'- [CR-1] OPEN\n- [CR-3] FIXED') $(step "" "" "")"
eq "E2 CR-1 open after two cycles stops before cycle 3 although CR-3 was resolved" "ok ok stop|carried" "$OUT|$(reason)"
rm -f "$GJ" "$M/review.md"; : > "$M/fingerprints.jsonl"; ov 0
OUT="$(step "$A" "$A" $'- [CR-1] OPEN\n- [CR-2] OPEN') $(step "" "" "")"
eq "E3 a cycle that resolved nothing stops the loop" "ok stop|no-progress" "$OUT|$(reason)"

# ---- audit (N1-260 semantics, default budget 3) ----
ASKED='| fix | quality | A | [asked] | review fix cap reached | One more FAIL fix cycle | List under For Human Review | user chose 2 | codebase |'
AUTO='| fix | quality | A | [auto] | review fix cap reached | List under For Human Review | Prompt user | auto-accept | --- |'
AUTOD='| fix | quality | A | [auto-decided] | review-fix-cap-extra | One more FAIL fix cycle | For Human Review | SEC-5 Medium open | --- |'
GRANTED='| fix | quality | A | [granted] | review fix cap reached | auto extra round | ask the user | x | --- |'
ovl() { ov "$1"; shift
    printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OV"
    [ $# -eq 0 ] || printf '%s\n' "$@" >> "$OV"; }
cfg '{}'
ovl 3; eq "AU1 3-cycle progress-gated run -> ok" "ok" "$(n1_review_fix_audit "$OV")"
ovl 4; eq "AU2 a cycle past the budget without [asked] -> breach" "breach" "$(n1_review_fix_audit "$OV")"
ovl 4 "$ASKED"; eq "AU3 one [asked] option-2 row covers one extra cycle" "ok" "$(n1_review_fix_audit "$OV")"
ovl 4 "$AUTO" "$AUTOD"; eq "AU4 [auto]/[auto-decided] rows never authorize a cycle" "breach" "$(n1_review_fix_audit "$OV")"
ovl 4 "$GRANTED"; eq "AU5 the retired [granted] row no longer counts" "breach" "$(n1_review_fix_audit "$OV")"

# ---- fix step outcome telemetry (D9, AC12) ----
printf '{"cycle":1,"decision":"allow","reason":"first"}\n{"cycle":2,"decision":"deny","reason":"no-progress"}\n' > "$GJ"
: > "$M/fingerprints.jsonl"
n1_fingerprint_append "$M/fingerprints.jsonl" fa CR-1 High active 0
n1_fingerprint_append "$M/fingerprints.jsonl" fa CR-1 High carried 1 1
n1_fingerprint_append "$M/fingerprints.jsonl" fb CR-2 High resolved 1 0
eq "O1 outcome carries gate decisions, deny reason and per-round finding states" \
   '{"gate":[{"cycle":1,"decision":"allow","reason":"first"},{"cycle":2,"decision":"deny","reason":"no-progress"}],"states":[{"cycle":1,"carried":["CR-1"],"resolved":["CR-2"]}]}' \
   "$(n1_review_fix_outcome "$M")"
printf 'garbage\n' >> "$GJ"; eq "O2 a garbled log line is skipped" "2" "$(n1_review_fix_outcome "$M" | jq '.gate | length')"
eq "O3 missing files -> empty lists" '{"gate":[],"states":[]}' "$(n1_review_fix_outcome "$T/none")"

# ---- developer contract (D5, AC5) ----
rm -f "$GJ"
printf '### Verdict: FAIL\n- [CR-1] High lib/a.sh:1 — a\n- [SEC-1] Medium lib/b.sh:2 — b\n- [CR-2] Low lib/c.sh:1 — c\n' > "$M/review.md"
cat > "$M/implementation.md" <<'EOF'
## Fix Cycle 1
## Fixes Applied
- [CR-1] fixed: guarded the null path
- [SEC-1] disputed: the value is a public key id, not a secret
## Fix Cycle 2
- [CR-1] fixed: x
## Fix Cycle 3
- [CR-1] deferred: out of scope
- [SEC-1] needs-decision: rotate the key now?
## Fix Cycle 4
- [CR-1] fixed:
- [SEC-1] fixed: y
## Fix Cycle 5 (soft)
- [CR-1] fixed: s
- [SEC-1] fixed: s
EOF
eq "C1 every blocking ID has a contract line (sub-headings inside the section are fine)" "ok" "$(n1_fix_verify_result "$M" 1)"
eq "C2 the section is per cycle: cycle 2 misses SEC-1" "missing: SEC-1" "$(n1_fix_verify_result "$M" 2)"
n1_fix_verify_result "$M" 2 >/dev/null; eq "C2b rejection returns 1" "1" "$?"
eq "C2c a non-final rejection writes nothing" "no" "$([ -e "$GJ" ] && echo yes || echo no)"
eq "C3 a deferred line is not a contract word" "missing: CR-1" "$(n1_fix_verify_result "$M" 3)"
eq "C4 an empty reason counts as missing" "missing: CR-1" "$(n1_fix_verify_result "$M" 4)"
eq "C5 a (soft) section never satisfies a FAIL cycle" "missing: CR-1 SEC-1" "$(n1_fix_verify_result "$M" 5)"
n1_fix_verify_result "$M" 2 final >/dev/null
eq "C6 final rejection records the contract miss for the gate" '{"cycle":2,"contract":"missing"}' "$(cat "$GJ")"
ov 2; : > "$M/fingerprints.jsonl"; row CR-2 resolved 2
eq "C7 the next gate denies contract" "exhausted|contract" "$(gate)|$(reason)"
ov 1; : > "$M/fingerprints.jsonl"; row CR-2 resolved 1
eq "C8 a contract miss of another cycle does not deny this gate" "allow" "$(gate)"
eq "C9 an unreadable review.md fails closed" "missing: review.md" "$(n1_fix_verify_result "$T/none" 1)"

# ---- developer agent contract text (D5) ----
DV=agents/developer.md
eq "D1 developer Output Format shows contract lines" "3" "$(grep -cE '^- \[(CR-1|SEC-2|CR-4)\] (fixed|disputed|needs-decision): <' "$DV")"
eq "D2 developer names the rejecting helper" "1" "$(grep -cF 'n1_fix_verify_result' "$DV")"
eq "D3 in-scope findings are never deferred" "0" "$(grep -cF 'list in-scope findings you did not fix under `Findings deferred`' "$DV")"

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
