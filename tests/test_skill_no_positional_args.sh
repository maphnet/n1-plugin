#!/usr/bin/env bash
# N1-347: Claude Code substitutes $ARGUMENTS, $ARGUMENTS[N] and $N ($0 = first argument) in
# SKILL.md text before the model sees it, so a shell helper's $1 became the second skill
# argument (`n1-finish <ID> chained` read every config key as `.chained`). SKILL.md must contain
# no $<digit>, ${<digit>} or $ARGUMENTS; use $* or "$@" in helpers. Step files, references and
# agents are loaded via Read, are not substituted, and are out of scope.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
PAT='\$\{?[0-9]|\$ARGUMENTS'

# Self-check: the pattern matches the banned forms and skips the safe ones (guards against a vacuous grep).
for s in 'c() { x ".$1"; }' 'awk "{print $0}"' 'echo ${2}' 'see $ARGUMENTS[0]'; do
    if grep -qE "$PAT" <<<"$s"; then echo "PASS: pattern matches: $s"; else echo "FAIL: pattern misses: $s"; FAIL=1; fi
done
for s in 'c() { x ".$*"; }' 'f "$@"' 'echo "${N1_QUEUE_RUN_ID:-}"' "IFS=\$'\\t'"; do
    if grep -qE "$PAT" <<<"$s"; then echo "FAIL: pattern over-matches: $s"; FAIL=1; else echo "PASS: pattern skips: $s"; fi
done

hits=$(grep -nE "$PAT" skills/*/SKILL.md || true)
if [ -n "$hits" ]; then
    echo "FAIL: positional placeholder in SKILL.md (Claude Code substitutes it; use \$* or \"\$@\")"
    echo "$hits"
    FAIL=1
else
    echo "PASS: no positional placeholder in skills/*/SKILL.md"
fi
exit $FAIL
