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
advisory_has() {
    awk '/^## Advisory Mode Steps 1-3/{in_advisory=1} in_advisory' skills/n1-review/steps/01-analyze.md |
        rg -q --fixed-strings "$2" && pass "$1" || fail "$1"
}

has "Codex session routing uses the combined resolver" "n1_resolve_agent <name> <step-context> [astra-context]" hooks/session-start.sh
has "Codex session routing treats the combined result as authoritative" "tab-separated model/effort result is authoritative" hooks/session-start.sh
has "final review names its canonical Astra context" "final-whole-branch-review" skills/n1-review/steps/01-analyze.md
has "final review requires verified QA evidence" "Verdict: PASS" skills/n1-review/steps/01-analyze.md
has "final review recognizes the documented verdict heading" "grep -q '^### Verdict: PASS'" skills/n1-review/steps/01-analyze.md
advisory_has "advisory review uses the combined resolver" "n1_resolve_agent code-reviewer review"
advisory_has "advisory review explicitly omits Astra context" "Advisory PR review always omits the third Astra-context argument"
advisory_has "advisory verifier uses the combined resolver" 'Resolve the adversarial verifier with `n1_resolve_agent code-reviewer review`'
has "failed fix names its canonical Astra context" "failed-fix-escalation" skills/n1-start/steps/fix.md
has "failed fix requires two prior failures" "review_fix_cycle >= 2" skills/n1-start/steps/fix.md
has "architecture adjudication names its canonical context" "architecture-adjudication" skills/n1-start/steps/brainstorm.md
has "architecture adjudication requires competing cross-cutting designs" "at least two named designs" skills/n1-start/steps/brainstorm.md
has "plan review uses its normal step context" "n1_resolve_agent solution-architect plan-review" skills/n1-start/steps/plan-review.md
not_has "plan review has no false fallback-model claim" "fallback default for this plan-review" skills/n1-start/steps/plan-review.md
has "implementation uses the combined resolver" "n1_resolve_agent developer implementation" skills/n1-start/steps/implementation.md
has "review uses the combined resolver" "n1_resolve_agent code-reviewer review" skills/n1-start/steps/review.md
has "n1-start documents combined dispatch resolution" "n1_resolve_agent <agent-name> [context] [astra-context]" skills/n1-start/SKILL.md

# Documentation is part of the executable routing contract: users and maintainers must
# see the same tier, effort, exception, and parity boundaries the resolver enforces.
has "init documents the Opus-to-Sol baseline" 'Opus roles resolve to `gpt-5.6-sol`' skills/n1-init/steps/12-models.md
has "init documents the Sonnet-to-Terra baseline" 'Sonnet roles resolve to `gpt-5.6-terra`' skills/n1-init/steps/12-models.md
has "init documents the Haiku-to-Luna baseline" 'Haiku roles resolve to `gpt-5.6-luna`' skills/n1-init/steps/12-models.md
has "init documents the Codex medium effort floor" "medium effort floor" skills/n1-init/steps/12-models.md
has "init documents explicit low clamping with a warning" 'warns and resolves to `medium`' skills/n1-init/steps/12-models.md
has "init presents neutral recommendation for equivalent Codex choices" "No recommendation. The options are equivalent given the available evidence; select based on team preference." skills/n1-init/steps/12-models.md
has "host routing documents exact model precedence" "override > escalation > downgrade > task type > baseline" references/host-routing.md
has "host routing documents effort precedence" "explicit persona/host effort > global Codex default" references/host-routing.md
has "host routing documents effort fallback and floor" "frontmatter >" references/host-routing.md
has "host routing names final review Astra context" "final-whole-branch-review" references/host-routing.md
has "host routing names architecture Astra context" "architecture-adjudication" references/host-routing.md
has "host routing names failed-fix Astra context" "failed-fix-escalation" references/host-routing.md
has "host routing says Astra is opt-in" "opt-in" references/host-routing.md
has "host routing distinguishes baseline profile parity" "context-free generated profiles" references/host-routing.md
has "architecture defines exact baseline parity" "exact same model and effort" references/architecture.md
has "architecture lists all and only contextual differences" "The only permitted runtime/profile differences are a declared escalation, downgrade, task-type override, or eligible explicit Astra override." references/architecture.md
has "architecture names the NP-132 boundary" "NP-132" references/architecture.md
has "architecture excludes empirical validation from this policy" "empirical validation" references/architecture.md
has "README frames the mapping as workload policy" "N1 workload policy" README.md
has "README rejects cross-vendor quality equivalence" "do not demonstrate cross-vendor quality equivalence" README.md

workflow_files=(hooks/session-start.sh skills/n1-review/steps/01-analyze.md skills/n1-start/steps/fix.md skills/n1-start/steps/brainstorm.md skills/n1-start/steps/plan-review.md skills/n1-start/steps/implementation.md skills/n1-start/steps/review.md skills/n1-start/SKILL.md)
if rg -n --fixed-strings "gpt-6-astra" "${workflow_files[@]}"; then
    fail "workflow files do not hard-code the Astra model"
else
    pass "workflow files do not hard-code the Astra model"
fi

exit "$FAIL"
