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
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS ${N1H:+N1_HEADLESS=$N1H} python3 hooks/enforce-agent-policy.py "${CFG:-}" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
for N1H in "" 1; do
    eq "guard[headless=$N1H]: feature push allowed" 0 "$(pol 'source ~/.n1/preamble.sh; n1_codex_gate_check "T-1" && git push -u origin feat/x')"
    eq "guard[headless=$N1H]: force-with-lease feature push allowed" 0 "$(pol 'git push --force-with-lease -u origin feat/x')"
    eq "guard[headless=$N1H]: gh pr create allowed" 0 "$(pol 'gh pr create --title t --body-file /tmp/b --base main --draft')"
done
N1H=1
eq "guard: default-branch push still denied for pr-worker" 2 "$(pol 'git push origin HEAD:main')"
eq "guard: gh pr merge still denied for pr-worker" 2 "$(pol 'gh pr merge 7 --squash')"
N1H=
# SEC-1: merging authorized (mergeOnFinish + fullAuto) must not loosen pr-worker
CFG="$T/auth.json"; echo '{"finishWork":{"mergeOnFinish":true},"autonomy":{"fullAuto":true}}' > "$CFG"
for N1H in "" 1; do
    eq "authorized[headless=$N1H]: gh pr merge denied" 2 "$(pol 'gh pr merge 7 --squash')"
    eq "authorized[headless=$N1H]: default push denied" 2 "$(pol 'git push origin HEAD:main')"
    eq "authorized[headless=$N1H]: --confirmed pin denied" 2 "$(pol 'source ~/.n1/preamble.sh; n1_review_pin set 7 --confirmed')"
    eq "authorized[headless=$N1H]: run pointer clear denied" 2 "$(pol 'n1_active_run_clear')"
    eq "authorized[headless=$N1H]: step end denied" 2 "$(pol 'n1_step_end pr 1 success')"
    eq "authorized[headless=$N1H]: branch delete denied" 2 "$(pol 'git branch -D feat/x')"
    eq "authorized[headless=$N1H]: feature push allowed" 0 "$(pol 'git push -u origin feat/x')"
    eq "authorized[headless=$N1H]: gh pr create allowed" 0 "$(pol 'gh pr create --title t --body-file /tmp/b --base main')"
    eq "authorized[headless=$N1H]: gh pr comment allowed" 0 "$(pol 'gh pr comment 7 --body-file /tmp/c')"
done
CFG=; N1H=

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

# 3. pr step routing (pr.md) and the worker result parse (procedure).
PRF=skills/n1-start/steps/pr.md
PD=skills/n1-start/procedures/pr-worker-dispatch.md
has "pr.md: begin fence resolves the pr-worker model" "$PRF" 'n1_resolve_agent pr-worker'
has "pr.md: route line" "$PRF" 'echo route:worker \|\| echo route:inline'
has "pr.md: worker route points at the procedure" "$PRF" '`route:worker` → follow `procedures/pr-worker-dispatch\.md`'
has "pr.md: inline fallback keeps n1-pr" "$PRF" '`n1:n1-pr`\. Pass: `docUpdateMode: "autonomous"`'
has "pr.md: post-condition stays in the orchestrator" "$PRF" 'MISSING=\$\(n1_review_check_run\)'
has "pr.md: Pending stays in the orchestrator" "$PRF" '^## Pending$'
has "procedure: dispatches pr-worker" "$PD" 'Dispatch persona `pr-worker`'
has "procedure: Wait Contract" "$PD" 'Wait Contract'
for s in n1_merge_authorized 'gh pr merge' n1_step_end; do lacks "procedure: no $s" "$PD" "$s"; done
has "procedure: prompt falls back inline" "$PD" '^- `pr:prompt` .*invoke skill `n1:n1-pr`'
has "procedure: unknown falls back inline" "$PD" '^- `pr:unknown` .*invoke skill `n1:n1-pr`'

# Route probe: a dirty tree routes inline, where n1-pr's uncommitted-changes prompt reaches the user.
RL=$(grep -F 'echo route:worker' "$PRF" | head -1)
G="$T/g"; git init -q -b feat/x "$G"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$T/home/memory/T-1"; echo '{}' > "$T/home/config.json"
rt() { (cd "$G" && N1_HOME="$T/home" ID=T-1 bash -c "$RL" 2>&1); }
eq "route: clean tree -> worker" route:worker "$(rt)"
echo x > "$G/dirty"
eq "route: dirty tree -> inline" route:inline "$(rt)"
rm -f "$G/dirty"

# Result parse, incl. the AC4 n1-pr round trip: worker prompt stop -> pr:prompt -> inline n1-pr.
RES=$(awk '/^```bash/{c++; if(c==1){b=1;next}} b&&/^```/{exit} b' "$PD" \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e 's/<ID>/T-1/')
mkdir -p "$T/bin"; printf '#!/bin/sh\n[ -n "${FAKE_PR:-}" ] || exit 1\necho "$FAKE_PR"\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
pr_() { (cd "$G" && env -u N1_HEADLESS PATH="$T/bin:$PATH" N1_ROOT="$REPO" CLAUDE_PLUGIN_ROOT="$REPO" N1_HOME="$T/home" bash -c "$RES" 2>&1); }
F="$T/home/memory/T-1/pr-result.md"
printf 'status: complete\nreason: -\npr: 7\npr_url: https://github.com/o/r/pull/7\nbranch: feat/x\n' > "$F"
OUT=$(pr_); eq "parse: complete" pr:complete "$(head -1 <<<"$OUT")"
if grep -qxF 'pr-number:7 pr-url:https://github.com/o/r/pull/7 branch:feat/x' <<<"$OUT"; then ok "parse: complete relays PR fields"; else no "parse: complete relays PR fields ($OUT)"; fi
if grep -qx 'missing:' <<<"$OUT"; then ok "parse: complete runs the post-condition"; else no "parse: complete runs the post-condition ($OUT)"; fi
printf 'status: complete\nreason: -\npr: 7\npr_url: https://github.com/o/r/pull/8\n' > "$F"
eq "parse: url/number mismatch -> unknown" pr:unknown "$(pr_ | head -1)"
printf 'status: stopped\nreason: prompt: Uncommitted changes: commit them first?\n' > "$F"
eq "round trip: prompt stop -> pr:prompt" pr:prompt "$(pr_ | head -1)"
has "round trip: inline n1-pr still asks on uncommitted changes" skills/n1-pr/steps/01-prepare.md 'Uncommitted changes → commit first \(summarize, ask confirmation\)'
printf 'status: stopped\nreason: Rebase conflicts detected\n' > "$F"
OUT=$(pr_); eq "parse: plain stop -> pr:stopped" pr:stopped "$(head -1 <<<"$OUT")"
if grep -qxF 'reason:Rebase conflicts detected' <<<"$OUT"; then ok "parse: stop reason relayed"; else no "parse: stop reason relayed"; fi
printf 'status: stopped\nreason: Rebase conflicts detected\n' > "$F"
export FAKE_PR='9 https://github.com/o/r/pull/9'; OUT=$(pr_); unset FAKE_PR
eq "parse: stop with open PR -> pr:stopped" pr:stopped "$(head -1 <<<"$OUT")"
if grep -qF 'pr-number:9 pr-url:https://github.com/o/r/pull/9' <<<"$OUT"; then ok "parse: stop with open PR relays PR fields"; else no "parse: stop with open PR relays PR fields ($OUT)"; fi
printf 'status: stopped\nreason: Prompt:\n' > "$F"
eq "parse: odd-case empty prompt stop -> pr:prompt" pr:prompt "$(pr_ | head -1)"
printf 'status: stopped\nreason: bad\033[31m reason\n' > "$F"
if grep -qxF 'reason:bad[31m reason' <<<"$(pr_)"; then ok "parse: reason sanitized"; else no "parse: reason sanitized"; fi
lacks "persona: pin refusal is not a stop" "$P" 'pin refusal'
lacks "procedure: no unconsumed N1_HEADLESS input" "$PD" '^N1_HEADLESS:'
printf 'all good\n' > "$F"
eq "parse: garbage, no open PR -> unknown" pr:unknown "$(pr_ | head -1)"
export FAKE_PR='9 https://github.com/o/r/pull/9'; OUT=$(pr_); unset FAKE_PR
eq "parse: garbage, open PR -> unknown-open" pr:unknown-open "$(head -1 <<<"$OUT")"
rm -f "$F"
eq "parse: missing -> unknown" pr:unknown "$(pr_ | head -1)"
exit $FAIL
