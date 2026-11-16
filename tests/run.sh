#!/usr/bin/env bash
# Runs the named test files (default: every tests/test_*.sh; paths relative to the repo root) in parallel
# (N1_TEST_JOBS workers, default nproc/2); prints logs only for failing files and exits non-zero if any fails.
set -uo pipefail
cd "$(dirname "$0")/.."
files=("$@"); [ "${#files[@]}" -gt 0 ] || files=(tests/test_*.sh)
J=${N1_TEST_JOBS:-$(( $( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2) / 2 ))}
[ "$J" -ge 1 ] 2>/dev/null || J=1
N1_TEST_LOGDIR=$(mktemp -d); trap 'rm -rf "$N1_TEST_LOGDIR"' EXIT; export N1_TEST_LOGDIR
# ponytail: file size is the runtime proxy; biggest (slowest) files start first so the long tail starts early
ls -S "${files[@]}" 2>/dev/null | xargs -P "$J" -I{} bash -c 'n=$(basename "$1"); bash "$1" > "$N1_TEST_LOGDIR/$n.log" 2>&1 && touch "$N1_TEST_LOGDIR/$n.pass"' _ {}
status=0
for t in "${files[@]}"; do
    n=$(basename "$t"); echo "== $t"
    if [ ! -e "$N1_TEST_LOGDIR/$n.pass" ]; then status=1; cat "$N1_TEST_LOGDIR/$n.log" 2>/dev/null; echo "!! $t FAILED"; fi
done
[ "$status" -eq 0 ] && echo "ALL TEST FILES PASSED" || echo "SOME TEST FILES FAILED"
exit $status
