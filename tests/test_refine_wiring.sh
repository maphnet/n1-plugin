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

# --- Task 3: shared investigation step caller mode
I=skills/n1-start/steps/investigation-deliverable.md
has "caller mode block exists" '**Caller mode — n1-refine:**' "$I"
before "caller mode precedes Phase 1" '**Caller mode — n1-refine:**' '**Phase 1 — Produce Findings**' "$I"
line_has "caller mode remaps memory to refine/" '**Caller mode — n1-refine:**' 'memory/<ID>/refine/' "$I"
line_has "caller mode runs Phases 1-2 only" '**Caller mode — n1-refine:**' 'Run Phase 1 and Phase 2 only' "$I"
lacks "no dangling Brain-dump variant refs" 'Brain-dump variant' "$I"

# --- Task 4: product-analyst + queue intake markers
PA=agents/product-analyst.md
line_has "PA skip line lists refined marker after pinned sentence" 'already contains the marker `*Structured by N1*` or `*Restructured by N1*`, skip enrichment' '`*Refined by N1*`' "$PA"
lacks "PA skip line never mentions Briefed refined" 'Briefed by N1 (queue plan)*` (n1-refine' "$PA"
has "PA has refined block rule" '**Refined block rule:**' "$PA"
line_has "PA copies decisions verbatim" '**Refined block rule:**' '`### Decisions`' "$PA"
line_has "PA takes AC from the block only" '**Refined block rule:**' 'Take `### Acceptance Criteria` from the block only' "$PA"
lacks "PA does not match the post-brainstorm marker" 'Refined after design review' "$PA"
line_has "PA comment fallback needs the exact leading marker" '**Refined block rule:**' 'starts with exactly `*Refined by N1*`' "$PA"
line_has "queue intake counts refined as Adequate" '`Normalized by N1` (with or without' '`*Refined by N1*`' skills/n1-queue/steps/intake.md
has "architecture lists refined marker" '`*Refined by N1*`' references/architecture.md

# --- Task 5: design consumers
has "SA treats refined decisions as resolved" '**Refined decisions:**' agents/solution-architect.md
line_has "SA routes infeasible decisions to contradictions" '**Refined decisions:**' 'ticket_contradictions' agents/solution-architect.md
line_has "brainstormer never re-asks refined decisions" '*Refined by N1*' '`[refined]`' agents/brainstormer.md
line_has "n1-brainstorm never re-asks refined decisions" '**Refined decisions:**' '`[refined]`' skills/n1-brainstorm/SKILL.md

# --- Task 6: n1-refine dispatcher + fetch
R=skills/n1-refine
has "refine skill named" 'name: n1-refine' "$R/SKILL.md"
has "refine argument-hint" 'argument-hint: "<ticket-id> [--investigate]"' "$R/SKILL.md"
has "refine requires a ticket ID" 'Run `/n1:n1-ticket` first' "$R/SKILL.md"
has "refine documents queue-plan order" 'Run refine before `n1-queue --plan`' "$R/SKILL.md"
has "fetch disables enrichment" 'enrichmentEnabled=false' "$R/steps/01-fetch.md"
has "fetch writes under refine/" 'memory/<ID>/refine/ticket.md' "$R/steps/01-fetch.md"
has "fetch checks the author" 'getCurrentUser' "$R/steps/01-fetch.md"
has "unknown author defaults to comment" 'WRITE_MODE=comment' "$R/steps/01-fetch.md"
has "fetch reuses shared investigation step" 'skills/n1-start/steps/investigation-deliverable.md' "$R/steps/01-fetch.md"
has "fetch uses caller mode" 'Caller mode — n1-refine' "$R/steps/01-fetch.md"
lacks "refine never writes frontmatter" 'n1_write_frontmatter' "$R"
lacks "refine never touches overview.md by path" 'memory/$ID/overview.md' "$R"

exit $FAIL
