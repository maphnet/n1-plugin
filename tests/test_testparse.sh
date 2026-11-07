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

cat > "$T/pytest_full.txt" <<'EOF'
FAILED a/test_x.py::test_x - assert 0
FAILED b/test_x.py::TestK::test_y[p1] - assert 0
FAILED tests/[unit]/test_a.py::test_x[p1] - e
EOF
assert_eq "pytest default mode keeps bare names" "test_x
test_y" "$(n1_testparse_failed_names "$T/pytest_full.txt")"
assert_eq "pytest full mode keeps node id, strips [param], Class-nested" "a/test_x.py::test_x
b/test_x.py::TestK::test_y
tests/[unit]/test_a.py::test_x" "$(n1_testparse_failed_names "$T/pytest_full.txt" full)"

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

printf 'PASS: adds positive\nFAIL: adds negative\n' > "$T/n1_bare.txt"
assert_eq "n1 bare FAIL name" "adds negative" "$(n1_testparse_failed_names "$T/n1_bare.txt")"

printf 'PASS: adds positive\nFAIL: adds negative (expected=[1] actual=[0])\n' > "$T/n1_detail.txt"
assert_eq "n1 FAIL with detail" "adds negative" "$(n1_testparse_failed_names "$T/n1_detail.txt")"

# N1-336: shell helpers (tests/test_orca.sh no()) print "FAIL: <name> -- <detail>"; the detail is not part of the name.
printf "PASS: eq other\nFAIL: eq name -- expected 'a', got 'b'\n" > "$T/n1_suffix.txt"
assert_eq "n1 FAIL with -- detail suffix" "eq name" "$(n1_testparse_failed_names "$T/n1_suffix.txt")"
printf 'FAIL: eq name -- got (rc 1)\n' > "$T/n1_suffix_paren.txt"
assert_eq "n1 FAIL suffix whose detail ends in a paren group" "eq name" "$(n1_testparse_failed_names "$T/n1_suffix_paren.txt")"
printf 'PASS: H11: runs (rc 0)\n' > "$T/n1_pair_pass.txt"
printf "FAIL: H11: runs (rc 0) -- expected 'a', got 'b'\n" > "$T/n1_pair_fail.txt"
assert_eq "suffixed FAIL name equals its PASS name" "$(n1_testparse_passed_names "$T/n1_pair_pass.txt")" "$(n1_testparse_failed_names "$T/n1_pair_fail.txt")"

# N1-336: unittest errors print "ERROR: test_x (module.Class)" (3.11+: "(module.Class.test_x)").
printf '======================================================================\nERROR: test_x (module.Class)\n----------------------------------------------------------------------\nRan 2 tests in 0.001s\nFAILED (errors=1)\n' > "$T/unittest_error.txt"
assert_eq "unittest ERROR name" "test_x" "$(n1_testparse_failed_names "$T/unittest_error.txt")"
printf 'ERROR: test_y (pkg.mod.Class.test_y)\n' > "$T/unittest_error311.txt"
assert_eq "unittest 3.11+ ERROR name" "test_y" "$(n1_testparse_failed_names "$T/unittest_error311.txt")"
printf 'ERROR: test_z (pkg.Test.test_z) (value=1)\n' > "$T/unittest_subtest.txt"
assert_eq "unittest subtest ERROR name" "test_z" "$(n1_testparse_failed_names "$T/unittest_subtest.txt")"
printf 'ERROR: something failed\nERROR: could not connect (host down)\n' > "$T/generic_error.txt"
assert_eq "generic ERROR log lines are not test names" "" "$(n1_testparse_failed_names "$T/generic_error.txt")"

printf 'ERROR: tests.test_mod (unittest.loader._FailedTest.tests.test_mod)\n' > "$T/unittest_import.txt"
assert_eq "unittest import-failure ERROR is not a test name" "" "$(n1_testparse_failed_names "$T/unittest_import.txt")"
printf 'ERROR: setUpClass (mod.Class)\nERROR: setUpModule (mod)\nERROR: tearDownClass (mod.Class)\nERROR: tearDownModule (mod.Class)\n' > "$T/unittest_fixture.txt"
assert_eq "unittest fixture ERRORs are not test names" "" "$(n1_testparse_failed_names "$T/unittest_fixture.txt")"

printf 'PASS: adds positive\nPASS: shows total|auto (hook ignored)\nFAIL: adds negative\n' > "$T/n1_pass.txt"
assert_eq "n1 PASS names (trailing paren stripped, pipe kept)" "$(printf 'adds positive\nshows total|auto')" "$(n1_testparse_passed_names "$T/n1_pass.txt")"
assert_eq "go PASS name" "TestAddPositive" "$(n1_testparse_passed_names "$T/go.txt")"
assert_eq "TAP ok name (not ok excluded)" "adds positive" "$(n1_testparse_passed_names "$T/tap.txt")"
assert_eq "jest ✓ name" "adds positive numbers" "$(n1_testparse_passed_names "$T/jest.txt")"
assert_eq "pytest default prints no PASS names" "" "$(n1_testparse_passed_names "$T/pytest.txt")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
