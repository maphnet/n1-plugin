#!/usr/bin/env bash
# tests/test_testparse.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
source "$REPO_ROOT/lib/testparse.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

cat > "$T/pytest.txt" <<'EOF'
============================= test session starts ==============================
collected 3 items
tests/test_calc.py .F.                                                   [100%]
=================================== FAILURES ===================================
FAILED tests/test_calc.py::test_add_negative - assert 0 == 1
========================= 1 failed, 2 passed in 0.03s ==========================
EOF
assert_eq "pytest failed name" "test_add_negative" "$(n1_testparse_failed_names "$T/pytest.txt")"

cat > "$T/pytest0.txt" <<'EOF'
============================= test session starts ==============================
collected 0 items
============================ no tests ran in 0.01s =============================
EOF
if n1_testparse_zero_tests "$T/pytest0.txt"; then echo "PASS: pytest zero tests"; PASS=$((PASS+1)); else echo "FAIL: pytest zero tests"; FAIL=$((FAIL+1)); fi

cat > "$T/jest.txt" <<'EOF'
 FAIL  src/calc.test.ts
  ● calc › adds negative numbers
    expect(received).toBe(expected)
  ✓ adds positive numbers (2 ms)
  ✕ adds negative numbers (3 ms)
Tests:       1 failed, 1 passed, 2 total
EOF
assert_eq "jest failed name" "adds negative numbers" "$(n1_testparse_failed_names "$T/jest.txt")"

printf 'TAP version 13\n# Subtest: adds negative\nnot ok 2 - adds negative\nok 1 - adds positive\n# tests 2\n# pass 1\n# fail 1\n' > "$T/tap.txt"
assert_eq "node:test failed name" "adds negative" "$(n1_testparse_failed_names "$T/tap.txt")"

printf '  calc\n    ✓ adds positive\n    1) adds negative\n\n  1 passing (5ms)\n  1 failing\n\n  1) calc\n       adds negative:\n     AssertionError\n' > "$T/mocha.txt"
assert_eq "mocha failed name" "adds negative" "$(n1_testparse_failed_names "$T/mocha.txt")"

printf -- '--- FAIL: TestAddNegative (0.00s)\n    calc_test.go:12: got 0 want 1\n--- PASS: TestAddPositive (0.00s)\nFAIL\nFAIL\texample.com/calc\t0.004s\n' > "$T/go.txt"
assert_eq "go failed name" "TestAddNegative" "$(n1_testparse_failed_names "$T/go.txt")"

printf 'testing: warning: no tests to run\nok  \texample.com/calc\t0.002s [no tests to run]\n' > "$T/go0.txt"
if n1_testparse_zero_tests "$T/go0.txt"; then echo "PASS: go zero tests"; PASS=$((PASS+1)); else echo "FAIL: go zero tests"; FAIL=$((FAIL+1)); fi

printf '\033[31mFAILED tests/test_x.py::test_colored\033[0m - boom\n' > "$T/ansi.txt"
assert_eq "ansi stripped" "test_colored" "$(n1_testparse_failed_names "$T/ansi.txt")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
