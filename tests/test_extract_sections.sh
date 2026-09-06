#!/usr/bin/env bash
# tests/test_extract_sections.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "--- expected"; echo "$2"; echo "--- actual"; echo "$3"; FAIL=$((FAIL+1)); fi; }
source "$REPO_ROOT/lib/memory.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/brainstorm.md" <<'EOF'
# Brainstorm

## Context
Long narrative here.

## Acceptance Criteria
- AC1: exports CSV
- AC2: respects filters

### Notes on AC
nested note

## Approaches Considered
### Approach A
rejected
### Approach B
chosen

## Chosen Approach
Approach B because it is smaller.

## Open Questions
none
EOF
EXPECTED='## Acceptance Criteria
- AC1: exports CSV
- AC2: respects filters

### Notes on AC
nested note

## Chosen Approach
Approach B because it is smaller.
'
assert_eq "extracts AC and chosen approach with nested subsection" "$EXPECTED" "$(n1_extract_sections "$T/brainstorm.md" "acceptance criteria" "chosen approach|selected approach")
"
assert_eq "no match prints nothing" "" "$(n1_extract_sections "$T/brainstorm.md" "does not exist")"
echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
