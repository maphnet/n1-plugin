#!/usr/bin/env bash
# N1-216: shared question-format rule and the (Recommended) prompt sites that point to it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
DOC=references/question-format.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
lacks_tree() { # <label> <extended-regex> <path...>
    local label="$1" re="$2"; shift 2
    if grep -rqE -- "$re" "$@" 2>/dev/null; then
        echo "FAIL: $label"; grep -rnE -- "$re" "$@" | head -5; FAIL=1
    else echo "PASS: $label"; fi
}
expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}
pointer() { # <file>
    check "$1 points to question-format.md" 'references/question-format\.md' "$1"
}

# --- rule doc
if [ -f "$DOC" ]; then echo "PASS: question-format.md exists"; else echo "FAIL: question-format.md missing"; FAIL=1; fi
check "doc: recommended layout line" '^    1 — <option> \(Recommended\): <evidence>$' "$DOC"
check "doc: works-when layout line" '^    2 — <option>: works when <condition>$' "$DOC"
check "doc: verbatim No-recommendation sentence" 'No recommendation\. The options are equivalent given the available evidence; select based on team preference\.' "$DOC"
check "doc: not-recommended mark states a reason" '<option> \(not recommended\): <reason>' "$DOC"
check "doc: defers the tier split to the project rule" 'recommended-option project rule' "$DOC"
check "doc: capital-R marker" 'Always write the marker as `\(Recommended\)`' "$DOC"
check "doc: alternatives JSON shape" '"alternatives":\{"B":"works when <condition>"\}' "$DOC"
lacks_tree "no works-when note carries the marker" 'works when[^`]*\(Recommended' skills "$DOC"

# --- n1-refine
pointer skills/n1-refine/steps/02-loop.md
pointer skills/n1-refine/steps/03-write.md
check "02-loop: other options carry a works-when note" '^2 — <option>: works when <condition>$' skills/n1-refine/steps/02-loop.md
check "03-write: Cancel carries a works-when note" '^3 — Cancel: write nothing; works when ' skills/n1-refine/steps/03-write.md
expect "03-write: still exactly one (Recommended)" 1 "$(grep -cF '(Recommended)' skills/n1-refine/steps/03-write.md)"

# --- n1-init
for f in 01-prerequisites 03-tracker 08-local-testing 10-quality-config 11-rules; do
    pointer "skills/n1-init/steps/$f.md"
done
expect "01-prerequisites: every Skip carries a works-when note" 3 "$(grep -c '2 — Skip: works when ' skills/n1-init/steps/01-prerequisites.md)"
check "03-tracker: Atlassian option carries a works-when note" '^2 — Jira via Atlassian MCP: works when ' skills/n1-init/steps/03-tracker.md
check "10-quality-config: Hands-off normalised with evidence" '^1 — Hands-off \(Recommended\): .*lib/config\.sh' skills/n1-init/steps/10-quality-config.md
check "11-rules: starter rules normalised with evidence" '^1 — Yes, generate starter rules \(Recommended\): ' skills/n1-init/steps/11-rules.md
lacks_tree "no lowercase (recommended) mark under skills/" '\(recommended\)' skills

# --- n1-start
for f in steps/analysis.md steps/fix.md steps/investigation-deliverable.md procedures/ticket-watch-react.md; do
    pointer "skills/n1-start/$f"
done
check "fix.md keeps the pinned mark on option 1" 'Always mark \(Recommended\) on 1' skills/n1-start/steps/fix.md
check "ticket-watch-react: Re-plan carries a works-when note" 'Re-plan: works when ' skills/n1-start/procedures/ticket-watch-react.md

# --- n1-brainstorm
pointer skills/n1-brainstorm/SKILL.md
lacks "n1-brainstorm: no bare-word recommended answer" 'with a recommended answer for each' skills/n1-brainstorm/SKILL.md
lacks "n1-brainstorm: no bare-word recommended approach" 'accept the recommended one' skills/n1-brainstorm/SKILL.md
# --- n1-clean
pointer skills/n1-clean/steps/03-confirm.md
check "n1-clean: SKILL.md reads the confirm step" 'steps/03-confirm\.md' skills/n1-clean/SKILL.md
check "n1-clean: Select carries a works-when note" '^2 — Select which to remove \(Completed and Abandoned\): works when ' skills/n1-clean/steps/03-confirm.md
lacks "n1-clean: prompt moved out of SKILL.md" 'Remove all Stale and Completed \(Recommended' skills/n1-clean/SKILL.md

# --- n1-release, n1-rules, n1-queue
pointer skills/n1-release/steps/03b-release-notes.md
pointer skills/n1-rules/steps/01-manage.md
pointer skills/n1-queue/steps/preview.md
expect "03b: still exactly one (Recommended" 1 "$(grep -c '(Recommended' skills/n1-release/steps/03b-release-notes.md)"
check "03b: local-only option carries a works-when note" '^2 — Write the local file only: works when ' skills/n1-release/steps/03b-release-notes.md
check "01-manage: (not recommended) states its reason" '^2 — Keep as-is \(not recommended\): ' skills/n1-rules/steps/01-manage.md
check "01-manage: Rephrase carries a works-when note" '^1 — Rephrase: works when ' skills/n1-rules/steps/01-manage.md
expect "preview: three alternatives carry works-when notes" 3 "$(grep -cE '^[234]\. \*\*.*Works when ' skills/n1-queue/steps/preview.md)"

exit "$FAIL"
