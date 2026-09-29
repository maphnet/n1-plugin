#!/usr/bin/env bash
# tests/test_qa_verify_env_isolation.sh — verifyGate must not leak orchestrator env vars into the QA runner shell.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_MD="$REPO_ROOT/skills/n1-start/steps/qa.md"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

# Guard against regressing to the masking `eval "$RUNNER_CMD"` form.
if grep -q 'eval "\$RUNNER_CMD"' "$QA_MD"; then
  echo "FAIL: qa.md still uses eval \"\$RUNNER_CMD\" (env leak reintroduced)"; FAIL=$((FAIL+1))
else
  echo "PASS: qa.md does not use eval \"\$RUNNER_CMD\""; PASS=$((PASS+1))
fi
if grep -q 'env -i HOME="\$HOME" PATH="\$PATH" bash -c "\$RUNNER_CMD"' "$QA_MD"; then
  echo "PASS: qa.md runs RUNNER_CMD via env -i isolated shell"; PASS=$((PASS+1))
else
  echo "FAIL: qa.md does not run RUNNER_CMD via env -i isolated shell"; FAIL=$((FAIL+1))
fi

# Mechanism check: the exact isolation snippet used in qa.md strips ambient N1 vars.
export N1_RUN_ID="run-abc" N1_HOST="claude" ID="NP-238"
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c 'echo "${N1_RUN_ID:-}${N1_HOST:-}${ID:-}"')
assert_eq "isolated shell sees no ambient N1_RUN_ID/N1_HOST/ID" "" "$OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
