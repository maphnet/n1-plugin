#!/usr/bin/env bash
# N1-230: finish tail hand-off. tail-worker contract, gates staying in the
# orchestrator, result parse, worker read budget, finalize ordering.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1"; fi; }
lacks() { if grep -qE -- "$3" "$2" 2>/dev/null; then no "$1"; else ok "$1"; fi; }
P=agents/tail-worker.md
H=skills/n1-finish/steps/handoff.md
M2=skills/n1-finish/steps/02-merge.md
C6=skills/n1-finish/steps/06-cleanup.md
FZ=skills/n1-start/procedures/finalize.md

# 1. Persona: inherit-all (no tools:), never merges, pushes, asks, clears or removes.
has "persona: name" "$P" '^name: tail-worker$'
lacks "persona: no tools: allowlist (inherits tracker MCP)" "$P" '^tools:'
FORBID='gh pr merge|git push|git merge|n1_merge_authorized|n1_active_run_clear|n1_finish_cleanup|n1_containers_teardown|n1-release'
BAD=$(grep -nE "$FORBID" "$P" 2>/dev/null | grep -vE '^[0-9]+:- Never ' || true)
if [ -f "$P" ] && [ -z "$BAD" ]; then ok "persona: forbidden commands only inside Never bullets"; else no "persona: forbidden commands only inside Never bullets: $BAD"; fi
has "persona: never prompts" "$P" '^- Never ask the user'
has "persona: finalize runs follow-up File" "$P" 'followup-filing\.md` § File'
has "persona: finalize writes gate3.md" "$P" 'gate3\.md'
has "persona: finish writes finish-result.md" "$P" 'finish-result\.md'
has "persona: finish never runs the cleanup call" "$P" 'do not run § One Cleanup Call'
# Gate 3 sources moved out of finalize.md, not lost.
for s in 'Implementation Summary' 'verdict \+ Evidence' 'local-testing\.md' 'ticket_url' 'investigation-mode variant' 'PR: SKIPPED'; do
    has "persona: Gate 3 source $s" "$P" "$s"
done

exit $FAIL
