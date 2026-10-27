#!/usr/bin/env bash
# tests/test_resolve_type.sh — verify n1_resolve_type routing and N1_TYPE_MATCHED_BY
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

assert_eq() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
        PASS=$((PASS+1))
    else
        echo "FAIL: $1 (expected=[$2] actual=[$3])"
        FAIL=$((FAIL+1))
    fi
}

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/validation.sh"

# Case 1: title alone must NOT route to investigation (no tags, no type_field, no override)
n1_resolve_type "Investigate slow login" "" "" "" > "$T/out"
assert_eq "title alone does not route to investigation" "task" "$(cat "$T/out")"
assert_eq "matched_by default" "default" "$N1_TYPE_MATCHED_BY"

# Case 2: investigation tag routes to investigation
n1_resolve_type "Slow login" "investigation" "" "" > "$T/out"
assert_eq "tag routes to investigation" "investigation" "$(cat "$T/out")"
assert_eq "matched_by tags" "tags" "$N1_TYPE_MATCHED_BY"

# Case 3: type_field routes bug
n1_resolve_type "Slow login" "" "bug" "" > "$T/out"
assert_eq "type field routes bug" "bug" "$(cat "$T/out")"
assert_eq "matched_by type_field" "type_field" "$N1_TYPE_MATCHED_BY"

# Case 4: override wins over type_field
n1_resolve_type "x" "" "bug" "investigation" > "$T/out"
assert_eq "override wins" "investigation" "$(cat "$T/out")"
assert_eq "matched_by override" "override" "$N1_TYPE_MATCHED_BY"

# n1_title_hints_investigation positive
n1_title_hints_investigation "Investigate slow login" \
    && { echo "PASS: hint detects"; PASS=$((PASS+1)); } \
    || { echo "FAIL: hint detects"; FAIL=$((FAIL+1)); }

# n1_title_hints_investigation negative
n1_title_hints_investigation "Add CSV export" \
    && { echo "FAIL: hint negative"; FAIL=$((FAIL+1)); } \
    || { echo "PASS: hint negative"; PASS=$((PASS+1)); }

# pipeline.json must not have title_match on investigation
[ -z "$(jq -r '.types.investigation.detect.title_match // empty' "$REPO_ROOT/pipeline.json")" ] \
    && { echo "PASS: title_match removed"; PASS=$((PASS+1)); } \
    || { echo "FAIL: title_match removed"; FAIL=$((FAIL+1)); }

# Research keyword triggers hint
n1_title_hints_investigation "Research payment providers" \
    && { echo "PASS: hint detects research"; PASS=$((PASS+1)); } \
    || { echo "FAIL: hint detects research"; FAIL=$((FAIL+1)); }

# Spike keyword triggers hint
n1_title_hints_investigation "Spike: caching strategy" \
    && { echo "PASS: hint detects spike"; PASS=$((PASS+1)); } \
    || { echo "FAIL: hint detects spike"; FAIL=$((FAIL+1)); }

# Unrelated spike word does not falsely match
n1_title_hints_investigation "Fix login" \
    && { echo "FAIL: hint false positive on fix"; FAIL=$((FAIL+1)); } \
    || { echo "PASS: hint no false positive on fix"; PASS=$((PASS+1)); }

# N1-162: `<ID> --type <name>` splits into a ticket plus an override (input-parsing.md snippet)
echo '{"tracker":{"prefix":"N1"}}' > "$T/config.json"
split() { # <raw> -> "<detected>|<override>|<stripped>"
    local raw="$1" ov st
    ov=$(n1_parse_type_arg "$raw") || ov=""; st=$(n1_strip_type_arg "$raw")
    printf '%s|%s|%s' "$(n1_detect_input_type "$st" "$T/config.json")" "$ov" "$st"
}
assert_eq "raw ID with --type is a braindump (the old bug)" "braindump" "$(n1_detect_input_type "N1-162 --type task" "$T/config.json")"
assert_eq "ID --type task -> ticket + override" "ticket|task|N1-162" "$(split "N1-162 --type task")"
assert_eq "plain ID -> ticket, no override" "ticket||N1-162" "$(split "N1-162")"
assert_eq "brain dump unaffected" "braindump||fix the login page" "$(split "fix the login page")"
assert_eq "URL + --type survives normalization" "N1-162" "$(n1_extract_ticket_from_url "$(n1_strip_type_arg "https://x.atlassian.net/browse/N1-162 --type task")" "$T/config.json")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
