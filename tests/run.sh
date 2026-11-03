#!/usr/bin/env bash
# Runs every tests/test_*.sh in parallel (N1_TEST_JOBS workers, default nproc/2); exits non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
J=${N1_TEST_JOBS:-$(( $( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2) / 2 ))}
[ "$J" -ge 1 ] 2>/dev/null || J=1
N1_TEST_LOGDIR=$(mktemp -d); trap 'rm -rf "$N1_TEST_LOGDIR"' EXIT; export N1_TEST_LOGDIR
# ponytail: file size is the runtime proxy; biggest (slowest) files start first so the long tail starts early
ls -S tests/test_*.sh | xargs -P "$J" -I{} bash -c 'n=$(basename "$1"); bash "$1" > "$N1_TEST_LOGDIR/$n.log" 2>&1 && touch "$N1_TEST_LOGDIR/$n.pass"' _ {}
status=0
for t in tests/test_*.sh; do
    n=$(basename "$t"); echo "== $t"
    if [ ! -e "$N1_TEST_LOGDIR/$n.pass" ]; then status=1; cat "$N1_TEST_LOGDIR/$n.log" 2>/dev/null; echo "!! $t FAILED"; fi
done
[ "$status" -eq 0 ] && echo "ALL TEST FILES PASSED" || echo "SOME TEST FILES FAILED"
exit $status
