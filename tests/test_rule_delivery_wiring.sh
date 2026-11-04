#!/usr/bin/env bash
# N1-117: project rules reach the developer on every path (direct, Plan, fix cycle) and developer self-checks them.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
absent() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

IMPL=skills/n1-start/steps/implementation.md
check "rules rendered for developer on every route" 'agent_name=developer. on every route' "$IMPL"
absent "rules no longer rendered for implementer" 'agent_name=implementer' "$IMPL"
check "Plan path relays rules verbatim" 'RULES_BLOCK. \(relay verbatim, never paraphrase\)' "$IMPL"

check "rules-injection appends verbatim, never paraphrase" 'verbatim to the agent.s spawn prompt; never paraphrase' skills/n1-start/procedures/rules-injection.md

FIX=skills/n1-start/steps/fix.md
check "fix runs rules-injection for developer" 'rules-injection\.md. \(.agent_name=developer.\)' "$FIX"
check "fix appends RULES_BLOCK to developer prompt" 'append .\$RULES_BLOCK. to every developer prompt in this step' "$FIX"
check "fix passes every RULE-N finding regardless of severity" 'every .\[RULE-N\]. finding \(any severity\)' "$FIX"

IMPLSKILL=skills/n1-implement/SKILL.md
check "n1-implement input lists the rules block" 'Project rules block' "$IMPLSKILL"
check "Task Brief Template copies rules unchanged" 'Project rules \(copy the block from the dispatch prompt unchanged; omit if none\)' "$IMPLSKILL"
check "every developer dispatch incl. final-gate fix keeps the rules" 'every developer dispatch \(task, re-dispatch, fresh developer, final-gate fix\) includes it unchanged' "$IMPLSKILL"

DEV=agents/developer.md
check "developer has Rule self-check section" '^## Rule self-check' "$DEV"
check "self-check allows n/a with reason without blocking" '`n/a` with a reason is valid and never blocks' "$DEV"
check "self-check applies rule clauses literally to option lists" 'Option lists or prompts.*apply the rule clauses literally' "$DEV"

# N1-177: tech-writer render site and applies_to validation
PREP=skills/n1-pr/steps/01-prepare.md
check "n1-pr renders rules for tech-writer" 'n1_rules_for_agent "tech-writer"' "$PREP"
check "tech-writer Phase 1 spawn gets RULES_BLOCK" 'doc update mode, .RULES_BLOCK. \(verbatim' "$PREP"
check "tech-writer Phase 2 spawn gets RULES_BLOCK" 'brainstorm_gate_skipped.*RULES_BLOCK. \(verbatim' "$PREP"
check "re-dispatch keeps RULES_BLOCK" 'same inputs \(including .RULES_BLOCK.\) plus .phase: 2.' "$PREP"
check "tech-writer takes RULES_BLOCK input" 'Optional: .RULES_BLOCK. ' agents/tech-writer.md
check "tech-writer maps rules to Before deploy rows" 'Project rules.*Before deploy' agents/tech-writer.md
check "check validates applies_to" 'n1_rules_validate_applies_to' skills/n1-rules/steps/02-deny-hooks.md
check "check sources lib/rules.sh" 'source "\$N1_ROOT/lib/rules.sh"' skills/n1-rules/steps/02-deny-hooks.md
check "wizard sources lib/rules.sh" 'source "\$N1_ROOT/lib/rules.sh"' skills/n1-rules/steps/01-manage.md
check "wizard lists valid names from helper" 'n1_rules_valid_applies_to' skills/n1-rules/steps/01-manage.md
absent "wizard no hard-coded persona list" 'product-analyst., .solution-architect' skills/n1-rules/steps/01-manage.md

exit $FAIL
