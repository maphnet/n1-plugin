#!/usr/bin/env bash
# Guards the workflow-to-runtime resolver contract. These instructions are consumed by
# the host orchestrator, so the observable contract is the dispatched resolver form.
set -euo pipefail

cd "$(dirname "$0")/.."
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
has() { rg -q --fixed-strings "$2" "$3" && pass "$1" || fail "$1"; }
not_has() { ! rg -q --fixed-strings "$2" "$3" && pass "$1" || fail "$1"; }

has "Codex session routing uses the combined resolver" "n1_resolve_agent <name> <step-context> [astra-context]" hooks/session-start.sh
has "Codex session routing treats the combined result as authoritative" "tab-separated model/effort result is authoritative" hooks/session-start.sh
has "final review names its canonical Astra context" "final-whole-branch-review" skills/n1-review/steps/01-analyze.md
has "final review requires verified QA evidence" "Verdict: PASS" skills/n1-review/steps/01-analyze.md
has "failed fix names its canonical Astra context" "failed-fix-escalation" skills/n1-start/steps/fix.md
has "failed fix requires two prior failures" "review_fix_cycle >= 2" skills/n1-start/steps/fix.md
has "architecture adjudication names its canonical context" "architecture-adjudication" skills/n1-start/steps/brainstorm.md
has "architecture adjudication requires competing cross-cutting designs" "at least two named designs" skills/n1-start/steps/brainstorm.md
has "plan review uses its normal step context" "n1_resolve_agent solution-architect plan-review" skills/n1-start/steps/plan-review.md
not_has "plan review has no false fallback-model claim" "fallback default for this plan-review" skills/n1-start/steps/plan-review.md
has "implementation uses the combined resolver" "n1_resolve_agent developer implementation" skills/n1-start/steps/implementation.md
has "review uses the combined resolver" "n1_resolve_agent code-reviewer review" skills/n1-start/steps/review.md
has "n1-start documents combined dispatch resolution" "n1_resolve_agent <agent-name> [context] [astra-context]" skills/n1-start/SKILL.md

workflow_files=(hooks/session-start.sh skills/n1-review/steps/01-analyze.md skills/n1-start/steps/fix.md skills/n1-start/steps/brainstorm.md skills/n1-start/steps/plan-review.md skills/n1-start/steps/implementation.md skills/n1-start/steps/review.md skills/n1-start/SKILL.md)
if rg -n --fixed-strings "gpt-6-astra" "${workflow_files[@]}"; then
    fail "workflow files do not hard-code the Astra model"
else
    pass "workflow files do not hard-code the Astra model"
fi

exit "$FAIL"
