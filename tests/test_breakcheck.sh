#!/usr/bin/env bash
# tests/test_breakcheck.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
source "$REPO_ROOT/lib/breakcheck.sh"
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 0; }

make_repo() {  # $1 = dir
    git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
    mkdir -p "$1/tests"
    cat > "$1/app.py" <<'EOF'
def add(a, b):
    return a + b if a >= 0 else 0   # bug: negatives collapse to 0
EOF
    cat > "$1/run_tests.py" <<'EOF'
import importlib, sys, traceback
mod = importlib.import_module("tests.test_app")
names = [n for n in dir(mod) if n.startswith("test_")]
failed = []
for n in names:
    try:
        getattr(mod, n)()
    except Exception:
        failed.append(n)
print("collected %d items" % len(names))
for n in failed:
    print("FAILED tests/test_app.py::%s - assertion" % n)
print("%d failed, %d passed in 0.01s" % (len(failed), len(names) - len(failed)))
sys.exit(1 if failed else 0)
EOF
    : > "$1/tests/__init__.py"
    cat > "$1/tests/test_app.py" <<'EOF'
from app import add
def test_add_positive():
    assert add(1, 2) == 3
EOF
    git -C "$1" add -A; git -C "$1" commit -qm base
    git -C "$1" branch -q base
}

fix_repo() {  # $1 = dir, $2 = test body for regression
    cat > "$1/app.py" <<'EOF'
def add(a, b):
    return a + b
EOF
    cat >> "$1/tests/test_app.py" <<EOF
$2
EOF
    git -C "$1" add -A; git -C "$1" commit -qm fix
}

CMD='python3 run_tests.py'

# Case 1: real regression test → red-then-green
T1=$(mktemp -d); make_repo "$T1"
fix_repo "$T1" 'def test_add_negative():
    assert add(-1, 2) == 1'
OUT=$(n1_break_check base "$CMD" test_add_negative "$T1/bc.log" "$T1")
assert_eq "regression verdict" "red-then-green" "$(echo "$OUT" | jq -r .verdict)"
assert_eq "regression success" "true" "$(echo "$OUT" | jq -r .success)"
assert_eq "tree restored (HEAD content)" "    return a + b" "$(sed -n 2p "$T1/app.py")"
assert_eq "tree clean after check" "" "$(git -C "$T1" status --porcelain)"

# Case 2: hollow test independent of the fix → never-red
T2=$(mktemp -d); make_repo "$T2"
fix_repo "$T2" 'def test_add_hollow():
    assert add(1, 1) == 2'
OUT=$(n1_break_check base "$CMD" test_add_hollow "$T2/bc.log" "$T2")
assert_eq "hollow verdict" "never-red" "$(echo "$OUT" | jq -r .verdict)"

# Case 3: named test missing → inconclusive (revert run is green or shows other names only)
T3=$(mktemp -d); make_repo "$T3"
fix_repo "$T3" 'def test_add_negative():
    assert add(-1, 2) == 1'
OUT=$(n1_break_check base "$CMD" test_does_not_exist "$T3/bc.log" "$T3")
assert_eq "missing test verdict" "never-red" "$(echo "$OUT" | jq -r .verdict)"

# Case 4: syntax error on revert → inconclusive
T4=$(mktemp -d); make_repo "$T4"
cat > "$T4/app.py" <<'EOF'
def add(a, b):
    return a + b
def helper():
    return 1
EOF
cat >> "$T4/tests/test_app.py" <<'EOF'
from app import helper
def test_helper():
    assert helper() == 1
EOF
git -C "$T4" add -A; git -C "$T4" commit -qm fix
OUT=$(n1_break_check base "$CMD" test_helper "$T4/bc.log" "$T4")
assert_eq "import error verdict" "inconclusive" "$(echo "$OUT" | jq -r .verdict)"
assert_eq "import error kind" "inconclusive" "$(echo "$OUT" | jq -r .error.kind)"

# Case 5: dirty tree → exit 2, kind dirty-tree
T5=$(mktemp -d); make_repo "$T5"; echo x >> "$T5/app.py"
set +e; OUT=$(n1_break_check base "$CMD" test_add_positive "$T5/bc.log" "$T5"); RC=$?; set -e
assert_eq "dirty exit" "2" "$RC"
assert_eq "dirty kind" "dirty-tree" "$(echo "$OUT" | jq -r .error.kind)"

# Case 6: no non-test diff → exit 2, kind no-diff
T6=$(mktemp -d); make_repo "$T6"
cat >> "$T6/tests/test_app.py" <<'EOF'
def test_extra():
    assert True
EOF
git -C "$T6" add -A; git -C "$T6" commit -qm tests-only
set +e; OUT=$(n1_break_check base "$CMD" test_extra "$T6/bc.log" "$T6"); RC=$?; set -e
assert_eq "no-diff exit" "2" "$RC"
assert_eq "no-diff kind" "no-diff" "$(echo "$OUT" | jq -r .error.kind)"

# Test path classifier
n1_break_check_is_test_path "tests/test_app.py" && echo "PASS: tests/ path" && PASS=$((PASS+1)) || { echo "FAIL: tests/ path"; FAIL=$((FAIL+1)); }
n1_break_check_is_test_path "src/calc.spec.ts" && echo "PASS: spec path" && PASS=$((PASS+1)) || { echo "FAIL: spec path"; FAIL=$((FAIL+1)); }
n1_break_check_is_test_path "src/calc.ts" && { echo "FAIL: src path"; FAIL=$((FAIL+1)); } || { echo "PASS: src path"; PASS=$((PASS+1)); }

rm -rf "$T1" "$T2" "$T3" "$T4" "$T5" "$T6"
echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
