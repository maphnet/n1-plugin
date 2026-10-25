#!/usr/bin/env bash
# N1-128: review findings travel by file path; reviewers write their own findings file only when given an output path.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
CR=agents/code-reviewer.md
SR=agents/security-reviewer.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
refute() { # <label> <extended-regex> <file-or-dir>
    if grep -rqE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

for A in "$CR" "$SR"; do
    check "$A lists Write" '^tools: Read, Grep, Glob, Write$' "$A"
    check "$A writes only when given an output path" 'When the spawn prompt gives an output path' "$A"
    check "$A keeps inline return without a path" 'Without an output path, return the report inline' "$A"
    check "$A index covers every finding" 'One Index line per finding of every severity' "$A"
    refute "$A no longer claims Read-only" 'Read-only' "$A"
done

refute "n1-review does not pass reviewer output paths" 'review-cr\.md|review-sec\.md' skills/n1-review

exit $FAIL
