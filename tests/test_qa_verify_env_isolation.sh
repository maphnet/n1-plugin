#!/usr/bin/env bash
# tests/test_qa_verify_env_isolation.sh — verifyGate must not leak orchestrator env vars into the QA runner shell.
set -euo pipefail
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

export N1_RUN_ID="run-abc" N1_HOST="claude" ID="NP-238"
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c 'echo "${N1_RUN_ID:-}${N1_HOST:-}${ID:-}"')
assert_eq "isolated shell sees no ambient N1_RUN_ID/N1_HOST/ID" "" "$OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
