#!/usr/bin/env bash
# N1-445: plain-English intake brief in the n1-start ticket step + product-analyst brief: contract.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
T=skills/n1-start/steps/ticket.md
A=agents/product-analyst.md
G=skills/n1-start/procedures/output-gates.md
NEEDLE="grep -m1 '^brief: '"

has() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
line_has() { # <label> <needle> <also> <file>: some line containing needle also contains also
    if grep -F -- "$2" "$4" 2>/dev/null | grep -F -- "$3" >/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first a precedes first b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

# --- Wiring: ticket step
line_has "brief line skips queue children" "$NEEDLE" 'N1_QUEUE_RUN_ID' "$T"
line_has "brief line skips headless runs" "$NEEDLE" 'N1_HEADLESS' "$T"
line_has "brief line never fails the step" "$NEEDLE" '|| true' "$T"
before "brief prints before the Story/epic gate" "$NEEDLE" '**Story/epic**' "$T"
before "brief prints before the create prompt" "$NEEDLE" '**Tracker ticket creation**' "$T"
before "brief prints before the duplicate check" "$NEEDLE" '**Duplicate check:**' "$T"
line_has "brief prose continues without pausing" '**Brief:**' 'without pausing' "$T"
has "no-yield rule intact" 'IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user' "$T"

# --- Wiring: output gates + analyst contract
has "output gates allow the intake brief" '5) The intake brief.' "$G"
has "analyst defines the brief section" '## Compact Return — brief line' "$A"
line_has "analyst brief is a single line" 'ONE line' 'brief:' "$A"
line_has "analyst brief bans paths and jargon" 'no file paths' 'signal names' "$A"
has "analyst omits brief when too thin" 'Omit the line when the ticket is too thin to summarize' "$A"
before "brief section precedes Signal Emission" '## Compact Return — brief line' '## Signal Emission' "$A"
line_has "signals line lists brief: before n1:signals" 'LAST line of your compact return' '`brief:`' "$A"

# --- Behavior: run the extracted line
BRIEF_LINE=$(grep -m1 -F -- "$NEEDLE" "$T")
if [ -z "$BRIEF_LINE" ]; then echo "FAIL: brief line not found in $T"; FAIL=1; fi
WANT='Users cannot log in. Sales calls are blocked. The ticket asks to fix the login form.'
OUT=$(printf 'intake-result: {"title": "Login"}\ntitle: Fix login\nbrief: %s\nn1:signals task_type=bug\n' "$WANT")
NOBRIEF=$(printf 'intake-result: {"title": "Login"}\ntitle: Fix login\nn1:signals task_type=bug\n')

expect() { # <label> <expected-stdout> <env assignments...>
    local label="$1" want="$2" got rc; shift 2
    got=$(env -u N1_QUEUE_RUN_ID -u N1_HEADLESS "$@" bash -ec "$BRIEF_LINE" 2>&1); rc=$?
    if [ -n "$BRIEF_LINE" ] && [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then echo "PASS: $label"
    else echo "FAIL: $label (rc=$rc, got: $got)"; FAIL=1; fi
}
expect "interactive run prints the brief" "$WANT" AGENT_OUTPUT="$OUT"
expect "queue child prints nothing" "" AGENT_OUTPUT="$OUT" N1_QUEUE_RUN_ID=q-1
expect "headless run prints nothing" "" AGENT_OUTPUT="$OUT" N1_HEADLESS=1
expect "missing brief prints nothing and exits 0" "" AGENT_OUTPUT="$NOBRIEF"

exit "$FAIL"
