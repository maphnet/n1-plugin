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

# 2. Gates stay in the orchestrator; the hand-off is reachable only after a merge.
has "02: merge authorization re-check stays" "$M2" 'n1_merge_authorized'
has "02: reviewed-head pin stays" "$M2" 'n1_review_pin'
has "02: merge-head guard stays" "$M2" '--match-head-commit'
has "02: STOPs clear the finish marker" "$M2" 'n1_active_run_clear_if n1-finish'
has "01: finish marker armed in orchestrator" skills/n1-finish/steps/01-resolve-target.md 'n1_finish_mark'
LAST=$(grep -E '^## ' "$M2" | tail -1)
if [ "$LAST" = "## Hand-off" ]; then ok "02: Hand-off is the last section"; else no "02: Hand-off is the last section ($LAST)"; fi
has "02: a STOP never hands off" "$M2" 'a \*\*STOP\*\* never hands off'
for s in n1_merge_authorized n1_review_pin 'gh pr merge' 'n1_finish_mark'; do lacks "handoff.md: no $s" "$H" "$s"; done
has "handoff.md: dispatches tail-worker" "$H" 'n1_resolve_agent tail-worker finish'
has "handoff.md: stopped never cleans up or releases" "$H" 'no cleanup, no release routing'
has "handoff.md: stopped clears the finish marker" "$H" 'n1_active_run_clear_if n1-finish'
has "06: orchestrator keeps cleanup and release routing" "$C6" '\[orchestrator\] runs § One Cleanup Call.*release routing'
has "06: worker never runs the cleanup call" "$C6" '\[worker\].*never running § One Cleanup Call'

# 3. Dispatch clears stale results; the result parse maps garbage and missing to unknown.
blk() { awk -v n="$1" '/^```bash/{c++; if(c==n){b=1;next}} b&&/^```/{exit} b' "$H" \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e 's/<ID>/T-1/'; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q -b main
MD="$T/home/memory/T-1"; mkdir -p "$MD"; echo '{}' > "$T/home/config.json"
sh_() { (cd "$T" && N1_ROOT="$REPO" CLAUDE_PLUGIN_ROOT="$REPO" N1_HOME="$T/home" bash -c "$1" 2>&1); }
DIS=$(blk 1); RES=$(blk 2)
touch "$MD/finish-result.md" "$MD/finish-block.md" "$MD/finish-report.md"
OUT=$(sh_ "$DIS")
if [ ! -e "$MD/finish-result.md" ] && [ ! -e "$MD/finish-block.md" ] && [ ! -e "$MD/finish-report.md" ]; then ok "dispatch: stale result files cleared"; else no "dispatch: stale result files cleared"; fi
if grep -qx 'model:sonnet' <<<"$OUT"; then ok "dispatch: model resolved from persona"; else no "dispatch: model resolved from persona ($OUT)"; fi
tl() { local got; got=$(sh_ "$RES" | head -1); if [ "$got" = "tail:$1" ]; then ok "$2"; else no "$2 (got $got)"; fi; }
printf 'status: complete\nreason: -\n' > "$MD/finish-result.md"; echo '## Finish' > "$MD/finish-block.md"; echo 'Finish complete: T-1' > "$MD/finish-report.md"
tl complete "parse: complete with block and report"
rm "$MD/finish-block.md"
tl unknown "parse: complete without block -> unknown"
printf 'status: stopped\nreason: deploy failed: https://x/run/1\n' > "$MD/finish-result.md"
tl stopped "parse: stopped"
if sh_ "$RES" | grep -qxF 'deploy failed: https://x/run/1'; then ok "parse: stopped reason relayed"; else no "parse: stopped reason relayed"; fi
printf 'all good, done!\n' > "$MD/finish-result.md"
tl unknown "parse: garbage -> unknown"
rm -f "$MD/finish-result.md"
tl unknown "parse: missing result -> unknown"

# 4. AC1 static: the worker's mandatory reads stay far below a 60K-token start.
SZ=$(cat "$P" skills/n1-finish/steps/0[3-6]-*.md references/deployment-actions.md skills/n1-start/procedures/output-gates.md "$H" | wc -c)
if [ "$SZ" -lt 160000 ]; then ok "AC1: worker reads $SZ B < 160000"; else no "AC1: worker reads $SZ B < 160000"; fi

exit $FAIL
