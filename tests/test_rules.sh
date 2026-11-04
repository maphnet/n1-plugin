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

# N1-177: applies_to validation
V() { n1_rules_validate_applies_to "$1"; }
out=$(V "developer,code-reviewer"); rc=$?; assert_eq "valid list: no output" "" "$out"; assert_eq "valid list: rc 0" "0" "$rc"
out=$(V "devloper"); rc=$?; assert_eq "typo printed" "devloper" "$out"; assert_eq "typo rc 1" "1" "$rc"
out=$(V "developer,devloper,queue"); rc=$?; assert_eq "mixed prints both invalid" "devloper queue" "$(echo $out)"; assert_eq "mixed rc 1" "1" "$rc"
out=$(V "*"); rc=$?; assert_eq "star valid" "0" "$rc"
out=$(V "Developer"); rc=$?; assert_eq "case-sensitive" "Developer" "$out"
out=$(V "developer, ,qa-engineer"); rc=$?; assert_eq "empty/space tokens skipped" "0" "$rc"
assert_eq "valid set = star + agents/*.md" "$( { echo '*'; ls "$REPO_ROOT"/agents/*.md | xargs -n1 basename | sed 's/\.md$//' | sort; } )" "$(n1_rules_valid_applies_to)"
assert_eq "queue not valid" "0" "$(n1_rules_valid_applies_to | grep -cx queue)"
assert_eq "inert flags persona without render site" "implementer" "$(n1_rules_inert_applies_to "implementer,developer")"
assert_eq "tech-writer not inert" "" "$(n1_rules_inert_applies_to "tech-writer")"
sites=$( { grep -rhoE 'agent_name=[a-z-]+|n1_rules_for_agent "[a-z-]+"' "$REPO_ROOT/skills/" | sed -E 's/agent_name=//; s/n1_rules_for_agent "//; s/"//' ; } | sort -u)
assert_eq "render sites pinned to call sites" "$sites" "$(n1_rules_render_sites | sort)"
D="$T/rules"; mkdir "$D"; printf -- '---\napplies_to: tech-writer\n---\nbody\n' > "$D/tw.rule.md"
assert_eq "for_agent returns tech-writer rule" "$D/tw.rule.md" "$(n1_rules_for_agent tech-writer "" "$D")"

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
