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

FIX=skills/n1-start/steps/fix.md
check "fix runs rules-injection for developer" 'rules-injection\.md. \(.agent_name=developer.\)' "$FIX"
check "fix appends RULES_BLOCK to developer prompt" 'append .\$RULES_BLOCK. to the developer prompt' "$FIX"
check "fix passes every RULE-N finding regardless of severity" 'every .\[RULE-N\]. finding \(any severity\)' "$FIX"

IMPLSKILL=skills/n1-implement/SKILL.md
check "n1-implement input lists the rules block" 'Project rules block' "$IMPLSKILL"
check "Task Brief Template copies rules unchanged" 'Project rules \(copy the block from the dispatch prompt unchanged; omit if none\)' "$IMPLSKILL"
check "fix-loop re-dispatch keeps the rules" 'Every re-dispatch keeps the Project rules' "$IMPLSKILL"

DEV=agents/developer.md
check "developer has Rule self-check section" '^## Rule self-check' "$DEV"
check "self-check allows n/a without blocking" '`n/a` is valid and never blocks' "$DEV"
check "self-check applies rule clauses literally to option lists" 'Option lists or prompts.*apply the rule clauses literally' "$DEV"

exit $FAIL
