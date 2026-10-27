#!/usr/bin/env bash
# N1-162: n1-refine wiring: --investigate move, *Refined by N1* consumers, caller mode, refine skill.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

has() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <fixed-string> <file-or-dir>
    if grep -rqF -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
line_has() { # <label> <needle> <also> <file>: some line containing needle also contains also
    if grep -F -- "$2" "$4" 2>/dev/null | grep -F -- "$3" >/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first a precedes first b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

# --- Task 1: --investigate leaves n1-start
lacks "no INVESTIGATE_FLAG left in skills" "INVESTIGATE_FLAG" skills
lacks "no investigate_interactive left in skills" "investigate_interactive" skills
lacks "no investigate_interactive left in architecture" "investigate_interactive" references/architecture.md
lacks "n1-start argument-hint drops --investigate" "[--investigate]" skills/n1-start/SKILL.md
has "input-parsing rejects --investigate" '`--investigate` moved: run `/n1:n1-refine <ID> --investigate`' skills/n1-start/procedures/input-parsing.md
line_has "ticket step redirects only interactive investigation" 'Interactive investigation moved: run `/n1:n1-refine <ID> --investigate`' 'N1_HEADLESS=1' skills/n1-start/steps/ticket.md
lacks "brain-dump investigation variant removed" "**Brain-dump variant**" skills/n1-start/steps/investigation-deliverable.md
has "architecture points investigation to n1-refine" '/n1:n1-refine <ID> --investigate' references/architecture.md

# --- Task 2: n1-start guard + ledger tag
has "post-brainstorm enrichment skips refined tickets" 'skip the append if `*Refined by N1*`' skills/n1-start/steps/brainstorm.md
has "post-brainstorm marker unchanged" '*Refined after design review — N1*' skills/n1-start/steps/brainstorm.md
has "ledger documents [refined]" '`[refined]` human answered in n1-refine' skills/n1-start/ledger.md
has "ledger keeps [plan]" '`[plan]`' skills/n1-start/ledger.md
has "tech-writer orders [refined] with [plan]" '`[plan]`/`[refined]` before `[asked]`' skills/n1-start/ledger.md

exit $FAIL
