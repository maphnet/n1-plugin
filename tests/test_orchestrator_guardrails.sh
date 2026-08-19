#!/usr/bin/env bash
# Guardrail sentinels: each is a unique phrase in a skill file that forbids the
# orchestrator from doing subagent work in the main session. If a sentinel
# disappears, the guardrail was (probably accidentally) removed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_contains() {
    local label="$1" file="$2" needle="$3"
    if grep -qF -- "$needle" "$REPO_ROOT/$file"; then
        echo "PASS: $label"
        PASS=$((PASS+1))
    else
        echo "FAIL: $label (missing in $file: $needle)"
        FAIL=$((FAIL+1))
    fi
}

# Task 2 — n1-ci
assert_contains "ci: orchestrator never remediates" \
    "skills/n1-ci/SKILL.md" \
    "ORCHESTRATOR GUARDRAIL (n1-ci): the orchestrator NEVER edits files, runs formatters, linters, compilers, package managers, or lock-file tools, and NEVER commits or pushes in this skill"
assert_contains "ci: developer fetches logs" \
    "skills/n1-ci/SKILL.md" \
    "Do NOT run \`gh run view --log-failed\` in the orchestrator"
assert_contains "ci: developer handles missing worktree" \
    "skills/n1-ci/SKILL.md" \
    "The worktree may already have been removed after PR creation"

# Task 3 — local testing / qa / review / ensure deps
assert_contains "local-testing: orchestrator prohibition" \
    "skills/n1-start/steps/local-testing.md" \
    "ORCHESTRATOR GUARDRAIL (local testing): do not run test suites"
assert_contains "local-testing: developer env step 0" \
    "skills/n1-start/steps/local-testing.md" \
    "0. Environment check: before anything else"
assert_contains "qa: no inline test runs" \
    "skills/n1-start/steps/qa.md" \
    "ORCHESTRATOR GUARDRAIL (qa): do not run tests, coverage, or lint commands in this step"
assert_contains "review: no inline test runs" \
    "skills/n1-start/steps/review.md" \
    "ORCHESTRATOR GUARDRAIL (review): do not run tests, coverage, or lint commands in this step"
assert_contains "ensure-deps: no inline debugging" \
    "skills/n1-start/SKILL.md" \
    "Do NOT diagnose or repair the environment inline"

# Task 4 — post-PR follow-ups
assert_contains "pr step: follow-up routing" \
    "skills/n1-start/steps/pr.md" \
    "ORCHESTRATOR GUARDRAIL (post-PR follow-ups)"
assert_contains "n1-pr: follow-up routing" \
    "skills/n1-pr/SKILL.md" \
    "ORCHESTRATOR GUARDRAIL (post-PR follow-ups)"

# Task 5 — brainstorm
assert_contains "brainstorm: no source reads" \
    "skills/n1-start/steps/brainstorm.md" \
    "ORCHESTRATOR GUARDRAIL (brainstorm): do NOT Read, Grep, Glob, \`cat\`, \`sed -n\`, or otherwise open project source files"

# Task 6 — investigation / ad-hoc experiments
assert_contains "investigation: experiments delegated" \
    "skills/n1-start/steps/investigation-deliverable.md" \
    "ORCHESTRATOR GUARDRAIL (experiments)"
assert_contains "brainstorm investigation: experiments delegated" \
    "skills/n1-start/steps/brainstorm.md" \
    "ORCHESTRATOR GUARDRAIL (experiments)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
