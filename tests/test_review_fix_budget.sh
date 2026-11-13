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

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
