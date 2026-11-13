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

# ---- summary ----
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
