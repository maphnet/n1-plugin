#!/usr/bin/env bash
# tests/test_rules.sh — N1-44: n1_rule_field must collapse ", " only for the
# list keys (applies_to, paths); free-text fields like description keep it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$REPO_ROOT/lib/rules.sh"

R="$T/x.rule.md"
printf -- '---\ndescription: Foo, bar, baz\napplies_to: a, b\npaths: x/**, y/**\n---\nbody\n' > "$R"

assert_eq "description keeps comma-space" "Foo, bar, baz" "$(n1_rule_field "$R" description)"
assert_eq "applies_to collapses" "a,b" "$(n1_rule_field "$R" applies_to)"
assert_eq "paths collapses" "x/**,y/**" "$(n1_rule_field "$R" paths)"

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
