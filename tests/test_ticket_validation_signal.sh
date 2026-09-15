#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/lib/signals.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected='$expected', got='$actual')"
        FAIL=$((FAIL+1))
    fi
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Test 1: write and read ticket_contradictions signal
cat > "$TMPDIR_TEST/analysis.md" << 'EOF'
## Codebase Analysis

### Ticket Validation
- Use Redis for caching — contradicted — https://example.com — SQLite recommended for this scale

<!-- n1:signals
blast_radius: low
-->
EOF

n1_write_signals "$TMPDIR_TEST/analysis.md" "ticket_contradictions=1"
actual=$(n1_read_signal "$TMPDIR_TEST/analysis.md" "ticket_contradictions")
assert_eq "write+read ticket_contradictions=1" "1" "$actual"

# Test 2: zero contradictions
cat > "$TMPDIR_TEST/analysis2.md" << 'EOF'
## Codebase Analysis

### Ticket Validation
No technical claims to validate

<!-- n1:signals
blast_radius: low
-->
EOF

n1_write_signals "$TMPDIR_TEST/analysis2.md" "ticket_contradictions=0"
actual=$(n1_read_signal "$TMPDIR_TEST/analysis2.md" "ticket_contradictions")
assert_eq "write+read ticket_contradictions=0" "0" "$actual"

# Test 3: default (missing signal) returns empty
cat > "$TMPDIR_TEST/analysis3.md" << 'EOF'
## Codebase Analysis

<!-- n1:signals
blast_radius: low
-->
EOF

actual=$(n1_read_signal "$TMPDIR_TEST/analysis3.md" "ticket_contradictions")
assert_eq "missing ticket_contradictions returns empty" "" "$actual"

# Test 4: signal coexists with existing signals
cat > "$TMPDIR_TEST/analysis4.md" << 'EOF'
## Codebase Analysis

<!-- n1:signals
blast_radius: medium
security_relevant: false
files_changed: 3
-->
EOF

n1_write_signals "$TMPDIR_TEST/analysis4.md" "ticket_contradictions=2"
actual_tc=$(n1_read_signal "$TMPDIR_TEST/analysis4.md" "ticket_contradictions")
actual_br=$(n1_read_signal "$TMPDIR_TEST/analysis4.md" "blast_radius")
assert_eq "ticket_contradictions alongside others" "2" "$actual_tc"
assert_eq "blast_radius preserved" "medium" "$actual_br"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
