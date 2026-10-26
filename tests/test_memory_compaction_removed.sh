#!/usr/bin/env bash
# tests/test_memory_compaction_removed.sh (N1-145)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1"; echo "--- expected"; echo "$2"; echo "--- actual"; echo "$3"; FAIL=$((FAIL+1)); fi; }

# Wiring: nothing under skills/ agents/ lib/ hooks/ may reference compaction or its *.full.md output
assert_eq "no compaction references" "" "$(grep -rlE 'n1_compact_memory|\.full\.md' "$REPO_ROOT/skills" "$REPO_ROOT/agents" "$REPO_ROOT/lib" "$REPO_ROOT/hooks" || true)"

# Behavior: the real unknowns grep returns tags from every section
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ID=X; N1_HOME="$T"; mkdir -p "$T/memory/$ID"
cat > "$T/memory/$ID/analysis.md" <<'EOT'
## Conclusions
ok
### Data Flow
a <!-- n1:unknown: q1? -->
### Integration Points
b <!-- n1:unknown: q2? -->
### Risks
c <!-- n1:unknown: q3? -->
EOT
LINE=$(grep -m1 '^UNKNOWNS=\$(grep' "$REPO_ROOT/skills/n1-start/steps/analysis.md")
[ -n "$LINE" ] || { echo "FAIL: unknowns line not found"; exit 1; }
eval "$LINE"
assert_eq "all 3 unknowns returned" "q1?
q2?
q3?" "$UNKNOWNS"
assert_eq "UNKNOWN_COUNT=3" "3" "$UNKNOWN_COUNT"
echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
