#!/usr/bin/env bash
# N1-608: attended n1-start runs move the ticket to Blocked around a mid-run blocking question
# (best-effort) and back to In Progress after the answer; resume moves a stopped ticket back.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
absent() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
D=skills/n1-start
P=$D/procedures/attended-block.md

# Procedure contract
check "procedure exists" '^# Procedure: Attended Block' "$P"
check "reuses Headless Guard escalation step 1 for the move" 'autonomy-headless\.md .*Headless Guard.* escalation step 1' "$P"
check "move is best-effort" 'best-effort' "$P"
check "reads blocked status via config helper" "n1_config_val '\.tracker\.statuses\.blocked'" "$P"
check "reads inProgress status via config helper" "n1_config_val '\.tracker\.statuses\.inProgress'" "$P"
check "skips when blocked is empty" '`BLOCKED_STATUS` is empty' "$P"
check "skips when blocked equals inProgress" '`BLOCKED_STATUS` equals `IN_PROGRESS_STATUS`' "$P"
check "skips headless runs" 'N1_HEADLESS' "$P"
check "sets the blocked_wait flag after a successful move" 'n1_write_frontmatter .*"blocked_wait" "true"' "$P"
check "clears the blocked_wait flag on unblock" 'n1_write_frontmatter .*"blocked_wait" "false"' "$P"
check "failed move never delays the question" 'go straight to the question' "$P"
check "stop leaves the ticket Blocked" 'stays Blocked' "$P"
absent "never writes step frontmatter (no step: escalated)" 'n1_write_frontmatter[^`]*"step"' "$P"

# AC4: headless and ask-mode text untouched
for f in autonomy-headless.md autonomy-headless-ask.md; do
    absent "headless $f untouched (no blocked_wait)" 'blocked_wait|attended-block' "$D/procedures/$f"
done

exit "$FAIL"
