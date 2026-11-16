#!/usr/bin/env bash
# N1-304: developer and fix runs stay targeted, QA runs the full suite once, and the queue-runner
# split keeps one definition per shared fixture helper.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

DEV=agents/developer.md
check "fix cycle runs only the covering test files" '^5\. \*\*Run only the test files covering your changes\*\*, not the full suite' "$DEV"
check "direct implementation runs only the covering test files" '^6\. \*\*Run only the test files covering your changes\*\* to verify nothing is broken, not the full suite' "$DEV"
check "QA runs the full suite once, then reruns only failing files" 'Run the full suite exactly once .*rerun only the failing test files' agents/qa-engineer.md
check "QA evidence documents Fixed test: lines for files QA fixed" '^Fixed test: \{test_file\} \| `' agents/qa-engineer.md
check "CLAUDE.md maps the queue-runner test areas" 'Queue runner tests are split by area' CLAUDE.md
for s in "" _bg _bg_chain _final_pr _orca _orca_liveness _orca_slots; do
    f=tests/test_queue_runner$s.sh
    if [ -z "$s" ]; then pat='`tests/test_queue_runner\.sh`'; else pat="\`${s}\\.sh\`"; fi
    check "CLAUDE.md map names $f" "$pat" CLAUDE.md
    if [ -f "$f" ]; then echo "PASS: $f exists"; else echo "FAIL: $f missing"; FAIL=1; fi
    if grep -qx 'n1_only_filter' "$f" 2>/dev/null; then echo "PASS: $f calls n1_only_filter"; else echo "FAIL: $f lacks n1_only_filter"; FAIL=1; fi
done

# N1-621: run.sh runs only the named files and fails on a named file that does not exist (never a silent green).
out=$(bash tests/run.sh tests/test_manifests.sh tests/test_n1621_missing.sh 2>&1); rc=$?
if [ "$rc" = 1 ] && [ "$(grep -c '^== ' <<< "$out")" = 2 ] && grep -qxF '!! tests/test_n1621_missing.sh FAILED' <<< "$out" \
    && ! grep -qF '!! tests/test_manifests.sh FAILED' <<< "$out"; then
    echo "PASS: run.sh runs only the named files"
else
    echo "FAIL: run.sh file args (rc=$rc)"; FAIL=1
fi

# N1-621: N1_TEST_ONLY runs only the named function; an unknown name exits 2 instead of an empty green run.
QF=tests/test_queue_runner_bg_chain.sh
out=$(N1_TEST_ONLY=test_merge_wording bash "$QF" 2>&1); rc=$?
labels=$(grep -E '^(PASS|FAIL): ' <<< "$out" | sed -E 's/^(PASS|FAIL): //' | cut -d: -f1 | LC_ALL=C sort -u)
if [ "$rc" = 0 ] && [ "$labels" = wording ]; then echo "PASS: N1_TEST_ONLY runs only the named function"; else echo "FAIL: N1_TEST_ONLY filter (rc=$rc labels=$labels)"; FAIL=1; fi
out=$(N1_TEST_ONLY=test_n1621_no_such_fn bash "$QF" 2>&1); rc=$?
if [ "$rc" = 2 ] && grep -qxF 'N1_TEST_ONLY: unknown test test_n1621_no_such_fn' <<< "$out"; then echo "PASS: N1_TEST_ONLY rejects an unknown name"; else echo "FAIL: N1_TEST_ONLY unknown name (rc=$rc)"; FAIL=1; fi

# Column-0 function definitions across the lib and every split file;ok/err/arg/msg live inside mk_orca's heredoc.
dups=$(grep -hoE '^[A-Za-z_][A-Za-z0-9_]*\(\) *\{' tests/queue_runner_lib.sh tests/test_queue_runner*.sh \
    | sed 's/(.*//' | grep -vxE 'ok|err|arg|msg' | LC_ALL=C sort | uniq -d)
if [ -z "$dups" ]; then echo "PASS: each queue-runner function defined once"; else echo "FAIL: defined twice: $dups"; FAIL=1; fi

exit $FAIL
