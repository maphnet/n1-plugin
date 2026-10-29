#!/usr/bin/env bash
# N1-17: n1-release pulls the default branch (ff-only) before any release step and stops on failure.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
F=skills/n1-release/steps/01-resolve-metadata.md
check() { if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
check "step 01 pulls ff-only on default branch" 'CURRENT == DEFAULT.*git pull --ff-only' "$F"
check "step 01 stops on pull failure" 'STOP with.*could not|STOP with.*Could not fast-forward' "$F"
check "step 01 names the stale-checkout reason" 'avoid releasing from a stale checkout' "$F"
exit $FAIL
