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

# Task 2 — n1-ci (guardrails live in steps/02-fix.md after sub-file refactoring)
assert_contains "ci: orchestrator never remediates" \
    "skills/n1-ci/steps/02-fix.md" \
    "ORCHESTRATOR GUARDRAIL (n1-ci): the orchestrator NEVER edits files, runs formatters, linters, compilers, package managers, or lock-file tools, and NEVER commits or pushes in this skill"
assert_contains "ci: developer fetches logs" \
    "skills/n1-ci/steps/02-fix.md" \
    "Do NOT run \`gh run view --log-failed\` in the orchestrator"
assert_contains "ci: developer handles missing worktree" \
    "skills/n1-ci/steps/02-fix.md" \
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
    "skills/n1-start/procedures/workspace-isolation.md" \
    "Do NOT diagnose or repair the environment inline"

# Task 4 — post-PR follow-ups
assert_contains "pr step: follow-up routing" \
    "skills/n1-start/steps/pr.md" \
    "ORCHESTRATOR GUARDRAIL (post-PR follow-ups)"
assert_contains "n1-pr: follow-up routing" \
    "skills/n1-pr/steps/02-push-create.md" \
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

# NP-144 — blocking dispatch requirement and post-dispatch verification gates
assert_contains "host-routing: blocking dispatch requirement" \
    "references/host-routing.md" \
    "BLOCKING DISPATCH REQUIREMENT"
assert_contains "brainstorm: post-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/brainstorm.md" \
    "n1_verify_dependencies"
assert_contains "brainstorm: wait directive" \
    "skills/n1-start/steps/brainstorm.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "plan: pre-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/plan.md" \
    "n1_verify_dependencies"
assert_contains "plan: wait directive" \
    "skills/n1-start/steps/plan.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "implementation: pre-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/implementation.md" \
    "n1_verify_dependencies"
assert_contains "implementation: wait directive" \
    "skills/n1-start/steps/implementation.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "review: pre-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/review.md" \
    "n1_verify_dependencies"
assert_contains "review: wait directive" \
    "skills/n1-start/steps/review.md" \
    "Wait for ALL reviewer personas to return"
assert_contains "fix: pre-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/fix.md" \
    "n1_verify_dependencies"
assert_contains "fix: wait directive" \
    "skills/n1-start/steps/fix.md" \
    "Wait for the developer persona to return"
assert_contains "pr: n1_verify_dependencies" \
    "skills/n1-start/steps/pr.md" \
    "n1_verify_dependencies"
assert_contains "estimation: n1_verify_dependencies" \
    "skills/n1-start/steps/estimation.md" \
    "n1_verify_dependencies"
assert_contains "plan-review: n1_verify_dependencies" \
    "skills/n1-start/steps/plan-review.md" \
    "n1_verify_dependencies"
assert_contains "plan-review: wait directive" \
    "skills/n1-start/steps/plan-review.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "investigation-deliverable: wait directive" \
    "skills/n1-start/steps/investigation-deliverable.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "investigation-deliverable: post-dispatch n1_verify_dependencies" \
    "skills/n1-start/steps/investigation-deliverable.md" \
    "n1_verify_dependencies"
assert_contains "qa: wait directive" \
    "skills/n1-start/steps/qa.md" \
    "Wait for the persona to return its result before proceeding"
assert_contains "qa: upstream implementation.md dependency check" \
    "skills/n1-start/steps/qa.md" \
    'n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md'
assert_contains "local-testing: planner wait directive" \
    "skills/n1-start/steps/local-testing.md" \
    "Wait for the persona to return its result before proceeding"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
