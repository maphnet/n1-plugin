#!/usr/bin/env bash
# N1-392: Codex triage runs in the tail-worker persona; the orchestrator handles
# paths, counts and status lines only. "The file-write mechanism" has one definition.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
has()   { if grep -qE -- "$3" "$2" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1 (missing /$3/ in $2)"; FAIL=1; fi; }
lacks() { if grep -qE -- "$3" "$2" 2>/dev/null; then echo "FAIL: $1 (still has /$3/ in $2)"; FAIL=1; else echo "PASS: $1"; fi; }

TW=agents/tail-worker.md
CT=skills/n1-pr/procedures/codex-triage.md
CW=skills/n1-pr/procedures/codex-triage-worker.md
P3=skills/n1-pr/steps/03-codex-review.md
FW=references/file-write-mechanism.md

# (e) one definition of the file-write mechanism, with the #44657 exception
has "definition names the #44657 exception"      "$FW" '#44657'
has "exception is the solution-architect"        "$FW" 'solution-architect'
has "definition forbids shell content writes"    "$FW" 'heredoc'
has "HOST ROUTING points to the definition"      hooks/session-start.sh 'references/file-write-mechanism\.md'
has "solution-architect cites its exception"     agents/solution-architect.md 'file-write-mechanism\.md'
has "tech-writer points to the definition"       agents/tech-writer.md 'file-write-mechanism\.md'
OTHERS=$(grep -lE 'NOT the Write tool|heredoc/cat redirect' agents/*.md 2>/dev/null | grep -v '^agents/solution-architect\.md$')
if [ -z "$OTHERS" ]; then echo "PASS: no other persona prescribes shell writes"; else echo "FAIL: personas contradict the definition: $OTHERS"; FAIL=1; fi

exit $FAIL
