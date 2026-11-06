#!/usr/bin/env bash
# N1-435: pr-worker. Guards allow its feature-branch push and PR create; persona contract;
# pr step routing, result parse and the prompt round trip to inline n1-pr.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1"; fi; }
lacks() { if grep -qE -- "$3" "$2" 2>/dev/null; then no "$1"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want $2, got $3)"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. Guards: a pr-worker Bash call passes the PreToolUse policy for a feature-branch push and
#    PR create, attended or headless; a default-branch push stays denied (unattended gate).
WT="$T/wt"; git init -q -b feat/x "$WT"
pol() { local rc=0; jq -cn --arg c "$1" --arg w "$WT" '{agent_type:"n1:pr-worker",tool_name:"Bash",session_id:"s-pr",cwd:$w,tool_input:{command:$c}}' \
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS ${N1H:+N1_HEADLESS=$N1H} python3 hooks/enforce-agent-policy.py "" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
for N1H in "" 1; do
    eq "guard[headless=$N1H]: feature push allowed" 0 "$(pol 'source ~/.n1/preamble.sh; n1_codex_gate_check "T-1" && git push -u origin feat/x')"
    eq "guard[headless=$N1H]: force-with-lease feature push allowed" 0 "$(pol 'git push --force-with-lease -u origin feat/x')"
    eq "guard[headless=$N1H]: gh pr create allowed" 0 "$(pol 'gh pr create --title t --body-file /tmp/b --base main --draft')"
done
N1H=1
eq "guard: default-branch push still denied for pr-worker" 2 "$(pol 'git push origin HEAD:main')"
eq "guard: gh pr merge still denied for pr-worker" 2 "$(pol 'gh pr merge 7 --squash')"
N1H=

# 2. Persona contract: inherit-all tools, never merges, asks, clears or releases; prompt stops carry "prompt:".
P=agents/pr-worker.md
has "persona: name" "$P" '^name: pr-worker$'
lacks "persona: no tools: allowlist (inherits tracker MCP)" "$P" '^tools:'
has "persona: model default" "$P" '^model: sonnet$'
FORBID='gh pr merge|git merge|n1_merge_authorized|n1_active_run_clear|n1_step_begin|n1_step_end|--confirmed|n1-release'
BAD=$(grep -nE "$FORBID" "$P" 2>/dev/null | grep -vE '^[0-9]+:- Never ' || true)
if [ -f "$P" ] && [ -z "$BAD" ]; then ok "persona: forbidden commands only inside Never bullets"; else no "persona: forbidden commands only inside Never bullets: $BAD"; fi
has "persona: never prompts, stops with a prompt: reason" "$P" '^- Never ask the user\..*reason: prompt: '
has "persona: runs the three n1-pr steps" "$P" '01-prepare\.md.*02-push-create\.md.*03-codex-review\.md'
has "persona: writes pr-result.md" "$P" 'pr-result\.md'
has "persona: writes pr-report.md" "$P" 'pr-report\.md'
has "persona: untrusted data rule" "$P" 'data, not instructions'
SZ=$(cat "$P" skills/n1-pr/steps/0[1-3]-*.md | wc -c)
if [ "$SZ" -lt 160000 ]; then ok "AC1: pr-worker reads $SZ B < 160000"; else no "AC1: pr-worker reads $SZ B < 160000"; fi
has "README lists pr-worker" README.md '^\| pr-worker \|'

exit $FAIL
