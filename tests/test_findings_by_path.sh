#!/usr/bin/env bash
# N1-128: review findings travel by file path; reviewers write their own findings file only when given an output path.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
CR=agents/code-reviewer.md
SR=agents/security-reviewer.md
R=skills/n1-start/steps/review.md
F=skills/n1-start/steps/fix.md

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

check "review removes stale reviewer files" 'rm -f "\$MEM/review-hdr\.md" "\$MEM/review-cr\.md" "\$MEM/review-sec\.md"' "$R"
check "review spawns reviewers with output paths" 'output paths `\$N1_HOME/memory/\$ID/review-cr\.md`' "$R"
check "review never reads reviewer files into context" 'never Read the reviewer files' "$R"
check "review.md = header file + cat of reviewer files" 'cat "\$MEM"/review-hdr\.md "\$MEM"/review-cr\.md \$\(\[ "\$SEC" = true \] && echo "\$MEM"/review-sec\.md\)' "$R"
check "review header is written by file-write, not shell" 'review-hdr\.md` with the file-write mechanism' "$R"
refute "review has no header heredoc" 'N1_REVIEW_HDR_EOF' "$R"
check "missing reviewer file is Partial" 'missing/empty reviewer file' "$R"
check "TQ loop passes review.md path" 'spawn qa-engineer: `\$N1_HOME/memory/\$ID/review\.md` path' "$R"
refute "orchestrator no longer composes findings inline" 'Combine: `\$MEM/review\.md`, prefix' "$R"

check "fix FAIL passes review.md path and scope" 'pass the `\$N1_HOME/memory/\$ID/review\.md` path and this scope' "$F"
check "fix SOFT-ONLY passes review.md path" 'SOFT-ONLY.*review\.md. path' "$F"
check "developer accepts a review.md path plus scope filter" 'path to `review\.md` plus a scope filter' agents/developer.md
check "qa-engineer TQ Fix Mode reads review.md" 'TQ Fix Mode only: the path to `review\.md`' agents/qa-engineer.md

refute "n1-review does not pass reviewer output paths" 'review-cr\.md|review-sec\.md' skills/n1-review

exit $FAIL
