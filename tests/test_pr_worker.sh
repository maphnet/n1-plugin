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
NH=  # N1-474: N1 home holding the s-pr run pointer; empty = no run (HOME is a temp dir, so no ~/.n1 pointer either)

# 1. Guards: a pr-worker Bash call passes the PreToolUse policy for a feature-branch push and
#    PR create, attended or headless; a default-branch push stays denied (unattended gate).
WT="$T/wt"; git init -q -b feat/x "$WT"
pol() { local rc=0; jq -cn --arg c "$1" --arg w "$WT" '{agent_type:"n1:pr-worker",tool_name:"Bash",session_id:"s-pr",cwd:$w,tool_input:{command:$c}}' \
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" ${N1H:+N1_HEADLESS=$N1H} ${NH:+N1_HOME=$NH} python3 hooks/enforce-agent-policy.py "${CFG:-}" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
for N1H in "" 1; do
    eq "guard[headless=$N1H]: feature push allowed" 0 "$(pol 'source ~/.n1/preamble.sh; n1_codex_gate_check "T-1" && git push -u origin feat/x')"
    eq "guard[headless=$N1H]: force-with-lease feature push allowed" 0 "$(pol 'git push --force-with-lease -u origin feat/x')"
    eq "guard[headless=$N1H]: gh pr create allowed" 0 "$(pol 'gh pr create --title t --body-file /tmp/b --base main --draft')"
done
N1H=1
eq "guard: default-branch push still denied for pr-worker" 2 "$(pol 'git push origin HEAD:main')"
eq "guard: gh pr merge still denied for pr-worker" 2 "$(pol 'gh pr merge 7 --squash')"
eq "guard: pr-worker commit staging n1-release skill allowed" 0 "$(pol 'git add skills/n1-release/SKILL.md && git commit -m "docs: n1-release notes"')"
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
# SEC-1 class: a dispatched subagent must not inherit the main session's merge authorization. It holds inside a run
# (keyed s-pr pointer) and in every unattended session; outside a run attended, non-worker subagents are plain (N1-474)
polx() { local rc=0; jq -cn --arg a "$1" --arg t "$2" --arg c "$3" --arg w "$WT" \
    '{tool_name:$t,session_id:"s-pr",cwd:$w,tool_input:(if $t=="Bash" then {command:$c} else {subagent_type:$c} end)} + (if $a=="" then {} else {agent_type:$a} end)' \
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" ${N1H:+N1_HEADLESS=$N1H} ${NH:+N1_HOME=$NH} python3 hooks/enforce-agent-policy.py "${CFG:-}" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
MRG="gh pr"" merge 7"
NH="$T/nh"; mkdir -p "$NH"; echo '{"ticketId":"N1-1"}' > "$NH/active-run.s-pr.json"
for N1H in "" 1; do
    for tool in Agent Task; do
        eq "spawn[$tool,headless=$N1H]: pr-worker -> general-purpose denied" 2 "$(polx n1:pr-worker $tool general-purpose)"
        eq "spawn[$tool,headless=$N1H]: pr-worker -> n1:developer denied" 2 "$(polx n1:pr-worker $tool n1:developer)"
        eq "spawn[$tool,headless=$N1H]: pr-worker -> n1:tech-writer allowed" 0 "$(polx n1:pr-worker $tool n1:tech-writer)"
        eq "spawn[$tool,headless=$N1H]: pr-worker -> n1:tail-worker allowed" 0 "$(polx n1:pr-worker $tool n1:tail-worker)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> general-purpose denied" 2 "$(polx n1:tail-worker $tool general-purpose)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> n1:tail-worker denied" 2 "$(polx n1:tail-worker $tool n1:tail-worker)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> n1:code-reviewer allowed" 0 "$(polx n1:tail-worker $tool n1:code-reviewer)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> n1:developer allowed" 0 "$(polx n1:tail-worker $tool n1:developer)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> n1:post-deploy-verifier allowed" 0 "$(polx n1:tail-worker $tool n1:post-deploy-verifier)"
        eq "spawn[$tool,headless=$N1H]: post-deploy-verifier -> n1:developer denied" 2 "$(polx n1:post-deploy-verifier $tool n1:developer)"
        eq "spawn[$tool,headless=$N1H]: tail-worker -> n1:tech-writer denied" 2 "$(polx n1:tail-worker $tool n1:tech-writer)"
    done
    for a in general-purpose n1:tech-writer n1:developer; do
        eq "authorized[headless=$N1H]: $a gh pr merge denied" 2 "$(polx $a Bash 'gh pr merge 7')"
        eq "authorized[headless=$N1H]: $a default push denied" 2 "$(polx $a Bash 'git push origin HEAD:main')"
    done
    eq "authorized[headless=$N1H]: tech-writer --confirmed denied" 2 "$(polx n1:tech-writer Bash 'source ~/.n1/preamble.sh; n1_review_pin set 7 --confirmed')"
    eq "authorized[headless=$N1H]: tech-writer run pointer clear denied" 2 "$(polx n1:tech-writer Bash 'n1_active_run_clear')"
    eq "authorized[headless=$N1H]: tech-writer docs commit allowed" 0 "$(polx n1:tech-writer Bash 'git add README.md && git commit -m "docs: update"')"
    eq "verifier[headless=$N1H]: git push denied" 2 "$(polx n1:post-deploy-verifier Bash 'git push origin feat')"
    eq "verifier[headless=$N1H]: gh pr comment denied" 2 "$(polx n1:post-deploy-verifier Bash 'gh pr comment 7 --body x')"
    eq "verifier[headless=$N1H]: health curl allowed" 0 "$(polx n1:post-deploy-verifier Bash 'curl -s http://localhost:8080/health')"
    # N1-474 CR-3: persona denies match in command position only; paths and commit text that mention them pass
    eq "cr3[headless=$N1H]: tech-writer commit staging n1-release skill allowed" 0 "$(polx n1:tech-writer Bash 'git add skills/n1-release/SKILL.md && git commit -m "docs: n1-release notes"')"
    eq "cr3[headless=$N1H]: tech-writer commit mentioning --confirmed allowed" 0 "$(polx n1:tech-writer Bash 'git commit -m "docs: describe the --confirmed re-pin"')"
    eq "cr3[headless=$N1H]: tech-writer commit mentioning n1_step_end allowed" 0 "$(polx n1:tech-writer Bash 'git commit -m "docs: mention n1_step_end and n1_review_pin"')"
    eq "cr3[headless=$N1H]: tech-writer commit mentioning branch delete allowed" 0 "$(polx n1:tech-writer Bash 'git commit -m "docs: git branch -D note"')"
    eq "cr3[headless=$N1H]: tech-writer diff of n1-clean skill allowed" 0 "$(polx n1:tech-writer Bash 'git diff skills/n1-clean/SKILL.md')"
    eq "cr3[headless=$N1H]: tech-writer step end denied" 2 "$(polx n1:tech-writer Bash 'n1_step_end pr 1 success')"
    eq "cr3[headless=$N1H]: tech-writer env-prefixed step begin denied" 2 "$(polx n1:tech-writer Bash 'FOO=1 n1_step_begin pr 1')"
    eq "cr3[headless=$N1H]: tech-writer bash -c run pointer clear denied" 2 "$(polx n1:tech-writer Bash "bash -c 'n1_active_run_clear'")"
    eq "cr3[headless=$N1H]: tech-writer quote-split orca rm denied" 2 "$(polx n1:tech-writer Bash "n1_orc''a_rm /x")"
    eq "cr3[headless=$N1H]: tech-writer worktree rm denied" 2 "$(polx n1:tech-writer Bash 'cd /w && git -C x worktree rm y')"
    eq "cr3[headless=$N1H]: tech-writer piped step end denied" 2 "$(polx n1:tech-writer Bash 'ls | n1_step_end a')"
    eq "cr3[headless=$N1H]: tech-writer then-keyword step end denied" 2 "$(polx n1:tech-writer Bash 'if true; then n1_step_end pr 1 success; fi')"
    eq "cr3[headless=$N1H]: tech-writer do-keyword run pointer clear denied" 2 "$(polx n1:tech-writer Bash 'for x in a; do n1_active_run_clear; done')"
    eq "cr3[headless=$N1H]: tech-writer brace-group step end denied" 2 "$(polx n1:tech-writer Bash '{ n1_step_end pr 1 success; }')"
    eq "cr3[headless=$N1H]: tech-writer sudo option value step end denied" 2 "$(polx n1:tech-writer Bash 'sudo -u root n1_step_end pr 1 success')"
    eq "cr3[headless=$N1H]: tech-writer quoted-assignment step end denied" 2 "$(polx n1:tech-writer Bash 'FOO="a b" n1_step_end pr 1 success')"
    eq "cr3[headless=$N1H]: tech-writer grep of n1_step_end allowed" 0 "$(polx n1:tech-writer Bash 'sudo -u root grep n1_step_end README.md')"
    # fix cycle 1: ReDoS, interpreter hand-offs, nested skill sessions, wrapper options, run-pointer tamper
    DOT=$(printf 'A="1" %.0s' $(seq 40)); SUDO=$(printf 'sudo -u env %.0s' $(seq 40))
    eq "fc1[headless=$N1H]: 40 quoted assignments then step end denied fast" 2 "$(timeout 10 bash -c "$(declare -f polx pol); WT='$WT' REPO='$REPO' T='$T' N1H='$N1H' NH='$NH' CFG=; polx n1:tech-writer Bash '${DOT}n1_step_end pr 1 success'")"
    eq "fc1[headless=$N1H]: 40 quoted assignments then echo allowed fast" 0 "$(timeout 10 bash -c "$(declare -f polx pol); WT='$WT' REPO='$REPO' T='$T' N1H='$N1H' NH='$NH' CFG=; polx n1:tech-writer Bash '${DOT}echo ok'")"
    eq "fc1[headless=$N1H]: 40 sudo -u env wrappers allowed fast" 0 "$(timeout 10 bash -c "$(declare -f polx pol); WT='$WT' REPO='$REPO' T='$T' N1H='$N1H' NH='$NH' CFG=; polx n1:tech-writer Bash '${SUDO}echo ok'")"
    for c in 'eval n1_step_end pr 1 success' 'echo n1_active_run_clear | bash' "bash <<< 'n1_step_end pr 1'" 'source <(echo n1_step_end pr 1)' \
        "bash -e -c 'n1_active_run_clear'" 'timeout -k 5 60 git worktree remove y' 'timeout --foreground 5 git branch -D x' '/usr/bin/git branch -D x' \
        $'n1_review_pin set 7 \\\n--confirmed' "claude --bg '/n1:n1-clean --ticket T-1'" "claude -p '/n1:n1-release'" 'sudo -u env -u env n1_step_end pr 1' \
        "eval $MRG" "echo '$MRG' | bash" "bash <<< '$MRG'" "source <(echo $MRG)" "timeout -s KILL 5 $MRG"; do
        eq "fc1[headless=$N1H]: pr-worker denies: $c" 2 "$(polx n1:pr-worker Bash "$c")"
    done
    eq "fc1[headless=$N1H]: tech-writer commit text with parens allowed" 0 "$(polx n1:tech-writer Bash 'git commit -m "docs: rename (n1_step_end)"')"
    eq "fc1[headless=$N1H]: tech-writer claude without n1-clean allowed" 0 "$(polx n1:tech-writer Bash 'git add skills/n1-clean/SKILL.md')"
    for w in n1:pr-worker n1:tail-worker n1:tech-writer; do
        for c in 'rm ~/.n1/x/active-run.s-pr.json' 'rm -f ~/.n1/*/active-run.*.json' 'mv ~/.n1/x/active-run.s-pr.json /tmp/z' 'truncate -s0 ~/.n1/x/active-run.s-pr.json' \
            'echo {} > ~/.n1/x/active-run.s-pr.json' 'ln -sf /tmp/z ~/.n1/x/active-run.s-pr.json' 'cp /dev/null ~/.n1/x/active-run.s-pr.json' \
            'find ~/.n1 -name active-run.s-pr.json -delete' "rm ~/.n1/x/active''-run.s-pr.json" 'sed -i s/a/b/ ~/.n1/x/active-run.s-pr.json'; do
            eq "fc1[headless=$N1H]: $w denies pointer tamper: $c" 2 "$(polx $w Bash "$c")"
        done
    done
    eq "fc1[headless=$N1H]: pointer read allowed" 0 "$(polx n1:pr-worker Bash 'cat ~/.n1/x/active-run.s-pr.json')"
    eq "authorized[headless=$N1H]: main session gh pr merge allowed" 0 "$(polx '' Bash 'gh pr merge 7')"
done
# N1-474 fix cycle 2: interpreter hand-off is read for pr-worker/tail-worker/tech-writer only; the generic gate (main
# session in a run, other subagents) is back to command-position matching, so message text is not a command (CR-6/SEC-7/CR-7)
CFG=; N1H=; NH="$T/nh"
for c in "git commit -m 'Forms like eval \$(x) and | bash now count, gh pr merge stays denied'" \
    "git commit -m 'grep -E (py|sh)\$ then gh pr merge notes'" "git commit -F- <<'EOF'
Forms like eval \$(x) now count, so gh pr merge from pr-worker stays denied. git push origin main too.
EOF" "git commit -m 'pointer -> active-run, n1_step_end and bash <<< gh pr merge'"; do
    eq "fc2: main session in run commit text allowed: ${c:0:50}" 0 "$(polx '' Bash "$c")"
    eq "fc2: developer in run commit text allowed: ${c:0:50}" 0 "$(polx n1:developer Bash "$c")"
done
eq "fc2: main session in run | bash merge text is not read as a command (as before N1-474)" 0 "$(polx '' Bash "echo '$MRG' | bash")"
# restricted workers: forms that hand text to another interpreter or delete the pointer indirectly (SEC-2/SEC-3/CR-4)
for w in n1:pr-worker n1:tail-worker n1:tech-writer; do
    for c in "echo '$MRG' | sudo bash" "echo '$MRG' | env bash" "echo '$MRG' | bash -" "echo '$MRG' | bash /dev/stdin" "bash < <(echo $MRG)" \
        "echo '$MRG' | ksh" "claude -p 'do it'" "python3 -c 'import os; os.system(\"$MRG\")'" "perl -e 'system \"$MRG\"'" \
        "awk 'BEGIN{system(\"$MRG\")}'" "find . -maxdepth 0 -exec $MRG \\;" "git -c alias.m='!$MRG' m" "case x in a) $MRG;; esac" \
        "echo 'git push origin HEAD:main' | bash" \
        "echo '$MRG' |& bash" "echo '$MRG' | (bash)" "echo '$MRG' | ( bash )" "echo '$MRG' | \"bash\"" "echo '$MRG' > >(bash)" \
        "echo '$MRG' |
bash" "echo '$MRG' | \\
bash" "git -c 'alias.m=!$MRG' m" "echo '$MRG' | python3" \
        "python3 -c 'import subprocess; subprocess.run([\"gh\",\"pr\",\"merge\",\"7\"])'" "perl -e 'system(\"gh\",\"pr\",\"merge\",7)'" \
        "ruby -e 'system(\"gh\",\"pr\",\"merge\",\"7\")'" "python3 -c 'import subprocess; subprocess.run([\"git\",\"push\",\"origin\",\"HEAD:main\"])'" \
        "python3 - <<'PY'
import subprocess
subprocess.run(\"$MRG\", shell=True)
PY" "python3 - <<'PY'
import subprocess
subprocess.run([\"gh\",\"pr\",\"merge\",\"7\"])
PY" "node <<<'require(\"child_process\").execSync(\"$MRG\")'" "sh <<'EOF'
$MRG
EOF"; do
        eq "fc2: $w denies: ${c:0:70}" 2 "$(polx $w Bash "$c")"
    done
done
for w in n1:pr-worker n1:tail-worker n1:tech-writer; do
    for c in 'rm ~/.n1/*/*.s-pr.json' 'rm ~/.n1/x/act*' 'rm -rf ~/.n1/x' 'mv ~/.n1 /tmp/z' 'rm -rf $N1_HOME' 'cd ~/.n1/x && rm *.json' \
        "find ~/.n1 -name 'active*' -delete" 'ls ~/.n1/*/active-run* | xargs rm' 'ls ~/.n1/x | xargs -n1 rm -f' \
        "python3 -c 'import glob,os;[os.remove(p) for p in glob.glob(\"$HOME/.n1/*/active*\")]'" "perl -e 'unlink glob q(~/.n1/x/active*)'" \
        'cd ~/.n1 && rm -rf n1-plugin' 'cd ~/.n1 && mv n1-plugin x' "find ~ -name 'act*' -delete" "find ~ -name '*.s-pr.json' -delete" \
        'ls ~/.n1/x/active-run* | env xargs rm' 'ls ~/.n1/x/active-run* | timeout 5 xargs rm' \
        "python3 - <<'PY'
import os
os.remove('$HOME/.n1/x/active-run.s-pr.json')
PY"; do
        eq "fc2: $w denies pointer tamper: $c" 2 "$(polx $w Bash "$c")"
    done
    eq "fc2: $w rm of a plain file allowed" 0 "$(polx $w Bash 'rm -f /tmp/x.tmp')"
    eq "fc2: $w commit text with arrow and | bash allowed" 0 "$(polx $w Bash 'git commit -m "docs: pointer -> active-run is read-only; a | bash b"')"
done
eq "fc2: pr-worker xargs rm of unrelated files allowed" 0 "$(polx n1:pr-worker Bash 'ls /tmp/x* | xargs rm')"
eq "fc2: pr-worker gh pr view piped to python allowed" 0 "$(polx n1:pr-worker Bash 'gh pr view 7 --json title | python3 -c "import json,sys; print(json.load(sys.stdin))"')"
eq "fc2: pr-worker grep for bash in a pipe allowed" 0 "$(polx n1:pr-worker Bash 'gh pr view 7 | grep -i bash')"
# SEC-6: every added regex is linear; a ~200KB adversarial command is decided fast (fail-open on hook timeout otherwise)
TJ="$T/adv.json"
for pat in 'eval ' '|' '>' '-sh ' 'sh ' 'sudo git ' 'env git ' 'env find ' 'env perl ' 'env python3 ' 'timeout xargs ' 'git alias. '; do
    for w in n1:pr-worker n1:tech-writer; do
        python3 - "$pat" "$TJ" "$w" <<'PY'
import json, sys
pat, out, w = sys.argv[1:4]
cmd = pat * (200000 // len(pat)) + "; echo ok"
json.dump({"agent_type": w, "tool_name": "Bash", "session_id": "s-pr", "cwd": "/tmp", "tool_input": {"command": cmd}}, open(out, "w"))
PY
        S=$(date +%s); timeout 20 env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" N1_HOME="$T/nh" python3 hooks/enforce-agent-policy.py "" "$REPO" < "$TJ" >/dev/null 2>"$T/adv.err"; RC=$?; E=$(date +%s)
        # the hook must decide (exit 0 allow or 2 deny, no traceback) in time: a crash or timeout would fail open
        if [ $((E - S)) -lt 5 ] && { [ $RC -eq 0 ] || [ $RC -eq 2 ]; } && ! grep -q Traceback "$T/adv.err"; then ok "fc2: 200KB '$pat' ($w) decided rc=$RC in under 5s"; else no "fc2: 200KB '$pat' ($w) rc=$RC took $((E - S))s"; fi
    done
done
# the wrapper-prefixed payload still reaches the merge: decision is a deny, not just fast
python3 - "$TJ" <<'PY'
import json, sys
json.dump({"agent_type": "n1:pr-worker", "tool_name": "Bash", "session_id": "s-pr", "cwd": "/tmp", "tool_input": {"command": "sudo git " * 20000 + "; echo 'gh pr merge 7' | bash"}}, open(sys.argv[1], "w"))
PY
timeout 20 env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" N1_HOME="$T/nh" python3 hooks/enforce-agent-policy.py "" "$REPO" < "$TJ" >/dev/null 2>&1; eq "fc3: 200KB 'sudo git ' then piped merge denied" 2 "$?"
CFG=; N1H=; NH=
# N1-474 CR-2: outside a run (no keyed pointer, no config) only pr-worker and tail-worker stay merge-gated when attended
for a in general-purpose n1:developer n1:tech-writer; do
    eq "no run, attended: $a merge allowed" 0 "$(polx $a Bash "$MRG")"
    eq "no run, attended: $a default push allowed" 0 "$(polx $a Bash 'git push origin HEAD:main')"
    N1H=1
    eq "no run, headless: $a merge denied" 2 "$(polx $a Bash "$MRG")"
    eq "no run, headless: $a default push denied" 2 "$(polx $a Bash 'git push origin HEAD:main')"
    N1H=
done
for a in n1:pr-worker n1:tail-worker; do
    eq "no run, attended: $a merge denied" 2 "$(polx $a Bash "$MRG")"
    eq "no run, attended: $a default push denied" 2 "$(polx $a Bash 'git push origin HEAD:main')"
done
eq "no run, attended: main session merge allowed" 0 "$(polx '' Bash "$MRG")"

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
printf 'status: stopped\nreason: prompt: late question\n' > "$F"
export FAKE_PR='9 https://github.com/o/r/pull/9'; OUT=$(pr_); unset FAKE_PR
eq "parse: prompt stop with open PR -> pr:stopped, not inline rerun" pr:stopped "$(head -1 <<<"$OUT")"
printf 'status: stopped\nreason: Prompt:\n' > "$F"
eq "parse: odd-case empty prompt stop -> pr:prompt" pr:prompt "$(pr_ | head -1)"
printf 'status: stopped\nreason: bad\033[31m reason\n' > "$F"
if grep -qxF 'reason:bad[31m reason' <<<"$(pr_)"; then ok "parse: reason sanitized"; else no "parse: reason sanitized"; fi
has "persona: pin/triage markers are not stops, write status: complete" "$P" 'pin:\*` and `triage:\*` markers are not stops.*write `status: complete`'
lacks "procedure: no unconsumed N1_HEADLESS input" "$PD" '^N1_HEADLESS:'
printf 'all good\n' > "$F"
eq "parse: garbage, no open PR -> unknown" pr:unknown "$(pr_ | head -1)"
export FAKE_PR='9 https://github.com/o/r/pull/9'; OUT=$(pr_); unset FAKE_PR
eq "parse: garbage, open PR -> stopped" pr:stopped "$(head -1 <<<"$OUT")"
if grep -qF 'reason:pr-worker returned no result; PR open, pin/triage unverified' <<<"$OUT" && ! grep -q '^missing:' <<<"$OUT"; then ok "parse: garbage, open PR -> reason, no missing check"; else no "parse: garbage, open PR -> reason, no missing check"; fi
rm -f "$F"
eq "parse: missing -> unknown" pr:unknown "$(pr_ | head -1)"
exit $FAIL
