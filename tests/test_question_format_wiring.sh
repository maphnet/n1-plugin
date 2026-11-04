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

exit "$FAIL"
