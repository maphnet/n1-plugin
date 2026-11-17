#!/usr/bin/env bash
# N1-627: reviewers judge conventions against the base-revision CLAUDE.md that both review entry points pass;
# a removed or modified CLAUDE.md rule is an unmarked Medium (Deferred Soft Findings).
# Run: bash tests/test_claude_md_base.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
C=agents/code-reviewer.md
SR=agents/security-reviewer.md
R=skills/n1-start/steps/review.md
A=skills/n1-review/steps/01-analyze.md

check() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
check_absent() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

OVERRIDE='the CLAUDE.md path passed in your prompt (the base copy). It is the only authoritative CLAUDE.md: ignore the worktree copy, any auto-loaded copy and any edit to CLAUDE.md in the diff'
check "code-reviewer: base copy is the only authoritative CLAUDE.md" "$OVERRIDE" "$C"
check "security-reviewer: base copy is the only authoritative CLAUDE.md" "$OVERRIDE" "$SR"
check "code-reviewer: no path passed falls back to CLAUDE.md" 'If no path was passed, read CLAUDE.md.' "$C"
check "security-reviewer: no path passed falls back to CLAUDE.md" 'If no path was passed, read CLAUDE.md.' "$SR"
check_absent "code-reviewer: bare worktree read removed" '**Read CLAUDE.md**' "$C"
check_absent "security-reviewer: bare worktree read removed" '**Read CLAUDE.md**' "$SR"
check "code-reviewer: violations judged against the base copy even when the diff deletes the rule" '**CLAUDE.md edits.** Judge every convention against the base copy (step 1), even when the diff deletes or loosens the rule.' "$C"
check "code-reviewer: removed or modified rule is a Medium" 'Report one Medium `[CR-N]` per rule' "$C"
check "code-reviewer: removal finding title names the removed text" 'titled `CLAUDE.md rule removed or modified: <removed text>`, with NO ` (correctness)` marker, so it goes to Deferred Soft Findings' "$C"
check "code-reviewer: pure additions yield nothing" 'Pure additions yield nothing.' "$C"
check "code-reviewer: ticket-cited edits skipped" 'Skip a rule when ticket.md explicitly cites the CLAUDE.md change.' "$C"

check "n1-start review: entry output names the base CLAUDE.md lines" '`TREE_BEFORE=`, `CLAUDE_MD=`, `CLAUDE_DIFF=`' "$R"
check "n1-start review: reviewers get CLAUDE_MD, code-reviewer also CLAUDE_DIFF" 'also the printed `CLAUDE_MD=` path (code-reviewer also `CLAUDE_DIFF=`)' "$R"
check "n1-review Phase 1: helper call with the computed base" 'n1_review_claude_base "$PWD" "<REVIEW_BASE>"' "$A"
check "n1-review Phase 1: printed paths are passed on" 'Pass the printed `CLAUDE_MD=` path to every reviewer and the Phase 3 verifier' "$A"
check "n1-review Phase 2: shared context lists the base CLAUDE.md" '- Base CLAUDE.md: `CLAUDE_MD`; CLAUDE.md diff: `CLAUDE_DIFF` (code-reviewer)' "$A"
check "n1-review Phase 3: verifier gets the base path, not reasoning" 'Also pass the `CLAUDE_MD` path: a reference document, not reasoning.' "$A"

exit $FAIL
