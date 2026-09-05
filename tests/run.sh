#!/usr/bin/env bash
# Runs every tests/test_*.sh; exits non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
for t in tests/test_*.sh; do
    echo "== $t"
    if ! bash "$t"; then status=1; echo "!! $t FAILED"; fi
done
[ "$status" -eq 0 ] && echo "ALL TEST FILES PASSED" || echo "SOME TEST FILES FAILED"
exit $status
