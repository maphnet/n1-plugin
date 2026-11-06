#!/usr/bin/env bash
# N1-445: plain-English intake brief in the n1-start ticket step + product-analyst brief: contract.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
T=skills/n1-start/steps/ticket.md
A=agents/product-analyst.md
G=skills/n1-start/procedures/output-gates.md
ENVREAD="printf 'QUEUE_RUN_ID=%s\\nHEADLESS=%s\\n' \"\${N1_QUEUE_RUN_ID:-}\" \"\${N1_HEADLESS:-}\""

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
line_has "intake block reads N1_QUEUE_RUN_ID" "$ENVREAD" 'N1_QUEUE_RUN_ID' "$T"
line_has "intake block reads N1_HEADLESS" "$ENVREAD" 'N1_HEADLESS' "$T"
before "env read sits in the intake block" 'ORIGINAL_STATUS=$(' "$ENVREAD" "$T"
line_has "brief prose names the analyst brief: line" '**Brief:**' '`brief:`' "$T"
line_has "brief prose gates on both values empty" '**Brief:**' 'both printed values are empty' "$T"
line_has "brief prose continues without pausing" '**Brief:**' 'without pausing' "$T"
before "brief prints before the Story/epic gate" '**Brief:**' '**Story/epic**' "$T"
before "brief prints before the create prompt" '**Brief:**' '**Tracker ticket creation**' "$T"
if grep -F -- "'^brief: '" "$T" >/dev/null 2>&1; then echo "FAIL: brief must not be piped through a shell string"; FAIL=1; else echo "PASS: no shell pipe for brief"; fi
has "no-yield rule intact" 'IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user' "$T"

# --- Wiring: output gates + analyst contract
has "output gates allow the intake brief" '5) The intake brief.' "$G"
has "budget table carves out the intake brief" 'Any inter-gate line (except the intake brief)' "$G"
has "analyst defines the brief section" '## Compact Return — brief line' "$A"
line_has "analyst brief is a single line" 'ONE line' 'brief:' "$A"
line_has "analyst brief bans paths and jargon" 'no file paths' 'signal names' "$A"
has "analyst omits brief when too thin" 'Omit the line when the ticket is too thin to summarize' "$A"
before "brief section precedes Signal Emission" '## Compact Return — brief line' '## Signal Emission' "$A"
line_has "signals line lists brief: before n1:signals" 'LAST line of your compact return' '`brief:`' "$A"

exit "$FAIL"
