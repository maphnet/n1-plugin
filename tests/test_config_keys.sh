#!/usr/bin/env bash
# tests/test_config_keys.sh -- N1-113: removed config keys have no reader/writer outside the
# n1-init prune list; n1_config_val never receives a literal 2nd arg (it is a FILE, not a default).
# Run: bash tests/test_config_keys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

HITS=$(grep -rnE "n1_config_val +['\"][^'\"]+['\"] +'" skills agents lib hooks scripts || true)
if [ -z "$HITS" ]; then ok "n1_config_val 2nd arg is never a literal"; else no "n1_config_val literal 2nd arg (use \${VAR:-default}):"; echo "$HITS"; fi

PRUNE=skills/n1-init/steps/01-prerequisites.md
DEAD=(
  qa.blockUntestedFeatures
  qa.verifyGate
  BLOCK_UNTESTED
)
for k in "${DEAD[@]}"; do
  HITS=$(grep -rnF -- "$k" skills lib hooks scripts defaults pipeline.json | grep -v "^$PRUNE:" || true)
  if [ -z "$HITS" ]; then ok "removed: $k"; else no "still referenced: $k"; echo "$HITS"; fi
done

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
