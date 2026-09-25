#!/usr/bin/env bash
# tests/test_investigation_deliverable_queue_gate.sh
# Verifies the Phase 5 queue-gate bash snippet in
# skills/n1-start/steps/investigation-deliverable.md (NP-198):
#   1. Decision Ledger header is inserted once and only once (idempotent guard)
#   2. CHOSEN branches correctly on ORIGINAL_STATUS present vs empty
#   3. the emitted row reflects the correct restore/leave-as-is text
#
# The snippet is extracted verbatim from the skill file (between the
# `source ~/.n1/preamble.sh` bash fence in the Phase 5 queue gate) so this
# test drifts with the skill instead of re-implementing its logic.
#
# Run: bash tests/test_investigation_deliverable_queue_gate.sh
# Expected: all tests PASS; exit 0.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/n1-start/steps/investigation-deliverable.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Extract the Phase 5 queue-gate bash block (the one that builds the Decision
# Ledger row) verbatim from the skill file.
# ---------------------------------------------------------------------------
BLOCK=$(awk '
    /^```bash$/ { in_block=1; buf=""; next }
    in_block && /^```$/ { if (buf ~ /Decision Ledger/) { print buf; exit }; in_block=0; next }
    in_block { buf = buf $0 "\n" }
' "$SKILL")

if [ -z "$BLOCK" ]; then
    fail "extract Decision Ledger bash block from $SKILL"
    echo "$FAIL failed, $PASS passed"
    exit 1
fi
pass "extract Decision Ledger bash block from $SKILL"

# The extracted block sources ~/.n1/preamble.sh (host plumbing, irrelevant
# here) and calls n1_read_frontmatter/n1_config_val. Strip the preamble line
# and provide the real lib functions directly so the test exercises the real
# logic.
BLOCK="${BLOCK//source ~\/.n1\/preamble.sh/:}"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/config.sh"
export -f n1_read_frontmatter n1_config_val n1_config_file n1_home

run_block() {
    local n1_home="$1" id="$2"
    ( N1_HOME="$n1_home" ID="$id" bash -c "$BLOCK" )
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- case 1: ORIGINAL_STATUS present + tracker capable -> Restore ---
mkdir -p "$WORK/case1/memory/T-1"
cat > "$WORK/case1/memory/T-1/overview.md" <<'EOF'
---
original_status: In Progress
---
# Overview
EOF
cat > "$WORK/case1/config.json" <<'EOF'
{"tracker": {"mcp": "youtrack", "operations": {"moveStatus": "update_issue"}}}
EOF
run_block "$WORK/case1" "T-1"
OUT1=$(cat "$WORK/case1/memory/T-1/overview.md")

if echo "$OUT1" | grep -q '^## Decision Ledger$'; then
    pass "case1: Decision Ledger header inserted"
else
    fail "case1: Decision Ledger header inserted"
fi

if echo "$OUT1" | grep -qF 'Restore to original status (In Progress)'; then
    pass "case1: CHOSEN reflects Restore with original status"
else
    fail "case1: CHOSEN reflects Restore with original status"
fi

# --- case 2: ORIGINAL_STATUS empty -> Leave as-is ---
mkdir -p "$WORK/case2/memory/T-2"
cat > "$WORK/case2/memory/T-2/overview.md" <<'EOF'
---
title: no status captured
---
# Overview
EOF
run_block "$WORK/case2" "T-2"
OUT2=$(cat "$WORK/case2/memory/T-2/overview.md")

if echo "$OUT2" | grep -qF 'Leave as-is (no original_status captured)'; then
    pass "case2: CHOSEN reflects Leave-as-is when original_status absent"
else
    fail "case2: CHOSEN reflects Leave-as-is when original_status absent"
fi

# --- case 3: idempotency -- running twice must not duplicate the header ---
run_block "$WORK/case1" "T-1"
HEADER_COUNT=$(grep -c '^## Decision Ledger$' "$WORK/case1/memory/T-1/overview.md")
if [ "$HEADER_COUNT" -eq 1 ]; then
    pass "case1: header stays singular after second run (idempotent guard)"
else
    fail "case1: header stays singular after second run (idempotent guard, got $HEADER_COUNT)"
fi

ROW_COUNT=$(grep -c 'investigation-deliverable | scope | B | \[auto\]' "$WORK/case1/memory/T-1/overview.md")
if [ "$ROW_COUNT" -eq 2 ]; then
    pass "case1: a new row is appended on each run (not deduped away)"
else
    fail "case1: a new row is appended on each run (got $ROW_COUNT rows)"
fi

# --- case 4: ORIGINAL_STATUS present but tracker can't move status ->
# ledger must NOT claim a restore that Restore-logic's own gate would refuse
# to perform (CR-1: audit-integrity — Chosen must match what actually runs).
mkdir -p "$WORK/case4/memory/T-4"
cat > "$WORK/case4/memory/T-4/overview.md" <<'EOF'
---
original_status: In Progress
---
# Overview
EOF
cat > "$WORK/case4/config.json" <<'EOF'
{"tracker": {"mcp": "youtrack", "operations": {}}}
EOF
run_block "$WORK/case4" "T-4"
OUT4=$(cat "$WORK/case4/memory/T-4/overview.md")
if echo "$OUT4" | grep -qF 'Leave as-is (no original_status captured)'; then
    pass "case4: no moveStatus op -> ledger does not claim restore"
else
    fail "case4: no moveStatus op -> ledger does not claim restore"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
