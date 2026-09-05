#!/usr/bin/env bash
# lib/testparse.sh — extract failing test names and zero-test detection from runner output.
# Supported: pytest, jest/vitest, node:test (TAP), mocha, go test. Framework auto-detected per line.

n1_testparse_strip_ansi() {
    sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "$1"
}

# n1_testparse_failed_names <output_file>
# Prints one failing test name per line. Empty output means no failures were recognized.
n1_testparse_failed_names() {
    local f="$1"
    [ -f "$f" ] || return 0
    n1_testparse_strip_ansi "$f" | awk '
        # pytest: "FAILED path::test_name - msg"  or "FAILED path::Class::test_name"
        /^FAILED [^ ]+::/ {
            s=$2; sub(/ .*/, "", s); n=split(s, parts, "::"); name=parts[n]; sub(/\[.*$/, "", name); print name; next
        }
        # jest / vitest: "  ✕ test name (3 ms)"  or "  × test name"
        /^[[:space:]]*(✕|×) / {
            line=$0; sub(/^[[:space:]]*(✕|×) /, "", line); sub(/ \([0-9]+ ?ms\)[[:space:]]*$/, "", line); print line; next
        }
        # node:test TAP: "not ok 2 - test name"
        /^[[:space:]]*not ok [0-9]+ - / {
            line=$0; sub(/^[[:space:]]*not ok [0-9]+ - /, "", line); sub(/ #.*$/, "", line); print line; next
        }
        # mocha: "    1) test name"  (only the summary list form, before the detail block)
        /^[[:space:]]+[0-9]+\) [^:]+$/ && !seen_detail {
            line=$0; sub(/^[[:space:]]+[0-9]+\) /, "", line); print line; next
        }
        /^[[:space:]]+[0-9]+ failing/ { seen_detail=1 }
        # go test: "--- FAIL: TestName (0.00s)"
        /^--- FAIL: / {
            name=$3; print name; next
        }
    ' | awk 'NF' | sort -u
}

# n1_testparse_zero_tests <output_file>
# Exit 0 when the runner reports that no tests were collected or executed.
n1_testparse_zero_tests() {
    local f="$1"
    [ -f "$f" ] || return 1
    n1_testparse_strip_ansi "$f" | grep -qiE \
        'no tests ran|collected 0 items|no tests to run|No tests found|Tests: +0 total|# tests 0$|0 passing$|No test files found'
}
