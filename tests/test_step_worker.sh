#!/usr/bin/env bash
# N1-645: ci-worker and local-testing-worker. lib/worker-step.sh helpers, hook boundaries, persona contract,
# question round trip and step wiring.
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

# 1. lib/worker-step.sh
WT="$T/wt"; git init -q -b feat/x "$WT"
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
MEM="$T/n1/memory/T-1"; mkdir -p "$MEM" "$T/home"
printf -- '---\nstep: ci\n---\n# T-1\n' > "$MEM/overview.md"
sw() { # <helper> [args...] — runs one lib helper in a fresh shell against the fixture
    (cd "$WT" && export HOME="$T/home" N1_ROOT="$REPO" N1_HOME="$T/n1" ID=T-1 \
        && source "$REPO/lib/preamble.sh" >/dev/null 2>&1; source "$REPO/lib/worker-step.sh" && "$@")
}
line() { sed -n "s/^$1://p" <<<"$2" | head -1; }

# entry
echo stale > "$MEM/ci-result.md"; echo stale > "$MEM/ci-question.md"
OUT=$(sw n1_sw_entry ci 42); RC=$?
eq "entry ci: rc 0" 0 "$RC"
has "entry ci: model line" <(echo "$OUT") "^model:.* memory:$MEM n1_root:$REPO worktree:"
eq "entry ci: input file" "pr: 42" "$(cat "$MEM/ci-input.md")"
eq "entry ci: stale result and question removed" "no no" "$([ -e "$MEM/ci-result.md" ] && echo yes || echo no) $([ -e "$MEM/ci-question.md" ] && echo yes || echo no)"
sw n1_sw_entry ci 'x; rm' >/dev/null 2>&1; eq "entry ci: non-numeric PR rejected" 1 "$?"
sw n1_sw_entry pr 1 >/dev/null 2>&1; eq "entry: unknown step rejected" 1 "$?"
printf 'Runner command: bash tests/run.sh\nRunner command: pytest -q\n' > "$MEM/qa.md"
sw n1_sw_entry lt >/dev/null
eq "entry lt: input file" "$(printf 'mode: live\nqa_runner_cmds: |\n  bash tests/run.sh\n  pytest -q')" "$(cat "$MEM/lt-input.md")"
rm -f "$MEM/qa.md"; sw n1_sw_entry lt >/dev/null
eq "entry lt: no qa.md -> empty block" "$(printf 'mode: live\nqa_runner_cmds: |')" "$(cat "$MEM/lt-input.md")"

# result
printf 'status: complete\nreason: -\noutcome: success\nmetadata: \n' > "$MEM/ci-result.md"
R=$(sw n1_sw_result ci)
eq "result ci: complete" complete "$(line sw "$R")"; eq "result ci: outcome" success "$(line outcome "$R")"; eq "result ci: no metadata" "" "$(line metadata "$R")"
printf 'status: complete\nreason: -\noutcome: success\nmetadata: { "action_type": "live", "infra_started": true }\n' > "$MEM/lt-result.md"
R=$(sw n1_sw_result lt)
eq "result lt: metadata compacted" '{"action_type":"live","infra_started":true}' "$(line metadata "$R")"
printf 'status: complete\nreason: -\noutcome: maybe\n' > "$MEM/lt-result.md"
eq "result: bad outcome -> unknown" unknown "$(line sw "$(sw n1_sw_result lt)")"
printf 'status: complete\noutcome: skipped\nmetadata: {"a":\n' > "$MEM/lt-result.md"
R=$(sw n1_sw_result lt); eq "result: bad JSON keeps complete" complete "$(line sw "$R")"; eq "result: bad JSON dropped" "" "$(line metadata "$R")"
printf 'status: complete\noutcome: skipped\nmetadata: [1,2]\n' > "$MEM/lt-result.md"
eq "result: non-object JSON dropped" "" "$(line metadata "$(sw n1_sw_result lt)")"
rm -f "$MEM/lt-result.md"; eq "result: missing file -> unknown" unknown "$(line sw "$(sw n1_sw_result lt)")"
printf 'status: stopped\nreason: prompt: Wait longer or skip?\n' > "$MEM/ci-result.md"
R=$(sw n1_sw_result ci); eq "result: prompt reason -> prompt" prompt "$(line sw "$R")"; eq "result: reason kept" "prompt: Wait longer or skip?" "$(line reason "$R")"
printf 'status: stopped\nreason: dependency install failed\n' > "$MEM/ci-result.md"
eq "result: plain stop" stopped "$(line sw "$(sw n1_sw_result ci)")"
printf 'status: question\nreason: -\n' > "$MEM/ci-result.md"; rm -f "$MEM/ci-question.md"
eq "result: question without question file -> unknown" unknown "$(line sw "$(sw n1_sw_result ci)")"

# auto-skip
git -C "$WT" rev-parse HEAD > "$MEM/branch-point"
echo doc > "$WT/README.md"; git -C "$WT" add README.md; git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m docs
eq "auto-skip: docs-only change skips" true "$(sw n1_sw_lt_auto_skip)"
echo 'echo hi' > "$WT/app.sh"; git -C "$WT" add app.sh; git -C "$WT" -c user.name=t -c user.email=t@t commit -q -m code
eq "auto-skip: runtime change does not skip" false "$(sw n1_sw_lt_auto_skip)"
echo deadbeef > "$MEM/branch-point"
eq "auto-skip: unresolvable base never skips" false "$(sw n1_sw_lt_auto_skip)"

# 2. Question round trip, lib side (AC4)
# ci mid-loop prompt: cap exhausted (skills/n1-ci/steps/02-fix.md Step 6b)
printf 'status: question\nreason: -\n' > "$MEM/ci-result.md"
printf '%s\n' 'class: ci-cap-exhausted' 'stop_list: none' 'recommended: none' \
    'question: After 3 CI fix attempts these checks still fail: lint. Options:' \
    'option: Provide guidance' 'option: Skip CI' 'option: Fix manually' > "$MEM/ci-question.md"
eq "roundtrip ci: result is question" question "$(line sw "$(sw n1_sw_result ci)")"
Q=$(sw n1_sw_question ci)
eq "roundtrip ci: class" ci-cap-exhausted "$(line class "$Q")"
eq "roundtrip ci: stop_list" none "$(line stop_list "$Q")"
eq "roundtrip ci: recommended" none "$(line recommended "$Q")"
eq "roundtrip ci: options in order" "Provide guidance|Skip CI|Fix manually" "$(sed -n 's/^option://p' <<<"$Q" | paste -sd'|')"
eq "roundtrip ci: question file consumed" no "$([ -e "$MEM/ci-question.md" ] && echo yes || echo no)"
# local-testing mid-loop prompt: 9d fix loop exhausted; option 2 matches the Autonomy gate action (local-testing-run.md 9d)
printf 'status: question\nreason: -\n' > "$MEM/lt-result.md"
printf '%s\n' 'class: lt-fix-exhausted' 'stop_list: none' 'recommended: 2' \
    'question: After 3 local testing fix cycles, these scenarios still fail: login. Options:' \
    "option: Fix manually, type 'continue' to re-test" 'option: Skip local testing, proceed to PR' \
    'option: Provide guidance for another fix attempt' > "$MEM/lt-question.md"
eq "roundtrip lt: result is question" question "$(line sw "$(sw n1_sw_result lt)")"
Q=$(sw n1_sw_question lt)
eq "roundtrip lt: class" lt-fix-exhausted "$(line class "$Q")"
eq "roundtrip lt: recommended" 2 "$(line recommended "$Q")"
eq "roundtrip lt: three options" 3 "$(grep -c '^option:' <<<"$Q")"
# fail-closed parsing
printf '%s\n' 'class: ci-escalate' 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' > "$MEM/ci-question.md"
eq "question: ci-escalate never has a recommendation" none "$(line recommended "$(sw n1_sw_question ci)")"
printf '%s\n' 'class: ci-made-up' 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' > "$MEM/ci-question.md"
Q=$(sw n1_sw_question ci); eq "question: unknown class" unknown "$(line class "$Q")"; eq "question: unknown class -> security" security "$(line stop_list "$Q")"
eq "question: unknown class -> no recommendation" none "$(line recommended "$Q")"
printf '%s\n' 'class: lt-fix-exhausted' 'recommended: 1' 'question: q' 'option: a' > "$MEM/lt-question.md"
eq "question: missing stop_list -> security" security "$(line stop_list "$(sw n1_sw_question lt)")"
printf '%s\n' 'class: lt-env-failure' 'stop_list: none' 'recommended: 5' 'question: q' 'option: a' 'option: b' > "$MEM/lt-question.md"
eq "question: out-of-range recommendation dropped" none "$(line recommended "$(sw n1_sw_question lt)")"
printf '%s\n' 'class: lt-fix-exhausted' 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' > "$MEM/ci-question.md"
eq "question: class from the other step rejected" unknown "$(line class "$(sw n1_sw_question ci)")"
rm -f "$MEM/ci-question.md"; eq "question: missing file" unknown "$(line class "$(sw n1_sw_question ci)")"

# N1-645 SEC-1/CR-2: the class fixes the recommendation; the worker's file field is ignored
for c in ci-low-confidence ci-not-branch-caused ci-cap-exhausted ci-pending-budget; do
    printf '%s\n' "class: $c" 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' 'option: b' > "$MEM/ci-question.md"
    eq "question: $c ignores file recommended" none "$(line recommended "$(sw n1_sw_question ci)")"
done
printf '%s\n' 'class: lt-env-failure' 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' 'option: b' > "$MEM/lt-question.md"
eq "question: lt-env-failure ignores file recommended" none "$(line recommended "$(sw n1_sw_question lt)")"
printf '%s\n' 'class: lt-fix-exhausted' 'stop_list: none' 'recommended: 1' 'question: q' 'option: a' 'option: b' > "$MEM/lt-question.md"
eq "question: lt-fix-exhausted is 2 whatever the file says" 2 "$(line recommended "$(sw n1_sw_question lt)")"
printf '%s\n' 'class: lt-fix-exhausted' 'stop_list: none' 'recommended: 2' 'question: q' 'option: a' > "$MEM/lt-question.md"
eq "question: lt-fix-exhausted with one option has none" none "$(line recommended "$(sw n1_sw_question lt)")"
# SEC-2: question/option wording can raise the stop list, the worker field cannot lower it
printf '%s\n' 'class: ci-cap-exhausted' 'stop_list: none' 'question: Fix touches the authentication flow' 'option: a' > "$MEM/ci-question.md"
eq "question: wording raises stop_list to security" security "$(line stop_list "$(sw n1_sw_question ci)")"
printf '%s\n' 'class: ci-cap-exhausted' 'stop_list: none' 'question: q' 'option: Change the public API' > "$MEM/ci-question.md"
eq "question: option wording raises stop_list to public-api" public-api "$(line stop_list "$(sw n1_sw_question ci)")"
printf '%s\n' 'class: ci-cap-exhausted' 'stop_list: architecture' 'question: lint failed' 'option: a' > "$MEM/ci-question.md"
eq "question: worker stop_list kept" architecture "$(line stop_list "$(sw n1_sw_question ci)")"
printf '%s\n' 'class: ci-cap-exhausted' 'stop_list: none' 'question: lint failed' 'option: a' > "$MEM/ci-question.md"
eq "question: plain prompt stays none" none "$(line stop_list "$(sw n1_sw_question ci)")"
# CR-1: a long question keeps its tail; long options stay intact
TAILQ="scenarios: login, logout, signup. Options:"
printf '%s\n' 'class: lt-fix-exhausted' 'stop_list: none' "question: $(printf 'x%.0s' $(seq 1 900)) $TAILQ" "option: $(printf 'y%.0s' $(seq 1 400))" 'option: b' > "$MEM/lt-question.md"
Q=$(sw n1_sw_question lt)
eq "question: long question keeps its tail" "$TAILQ" "$(line question "$Q" | grep -o 'scenarios:.*')"
eq "question: 400-char option intact" 400 "$(sed -n '1,/^option:/{/^option:/p}' <<<"$Q" | head -1 | sed 's/^option://' | tr -d '\n' | wc -c)"

# 3. Hook boundaries (AC6): spawn allowlist, step markers, push and merge
polx() { local rc=0; jq -cn --arg a "$1" --arg t "$2" --arg c "$3" --arg w "$WT" \
    '{tool_name:$t,session_id:"s-sw",cwd:$w,tool_input:(if $t=="Bash" then {command:$c} else {subagent_type:$c} end),agent_type:$a}' \
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" ${N1H:+N1_HEADLESS=$N1H} ${NH:+N1_HOME=$NH} python3 hooks/enforce-agent-policy.py "${CFG:-}" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
NH="$T/nh"; mkdir -p "$NH"; echo '{"ticketId":"T-1"}' > "$NH/active-run.s-sw.json"; CFG=
for N1H in "" 1; do
    for tool in Agent Task; do
        eq "spawn[$tool,$N1H]: ci-worker -> developer allowed" 0 "$(polx n1:ci-worker $tool n1:developer)"
        eq "spawn[$tool,$N1H]: ci-worker -> tech-writer allowed (PR body reconcile)" 0 "$(polx n1:ci-worker $tool n1:tech-writer)"
        for p in general-purpose n1:local-test-planner n1:ci-worker n1:tail-worker; do
            eq "spawn[$tool,$N1H]: ci-worker -> $p denied" 2 "$(polx n1:ci-worker $tool $p)"
        done
        eq "spawn[$tool,$N1H]: local-testing-worker -> developer allowed" 0 "$(polx n1:local-testing-worker $tool n1:developer)"
        eq "spawn[$tool,$N1H]: local-testing-worker -> local-test-planner allowed" 0 "$(polx n1:local-testing-worker $tool n1:local-test-planner)"
        for p in general-purpose n1:tech-writer n1:local-testing-worker n1:code-reviewer; do
            eq "spawn[$tool,$N1H]: local-testing-worker -> $p denied" 2 "$(polx n1:local-testing-worker $tool $p)"
        done
    done
    for w in n1:ci-worker n1:local-testing-worker; do
        eq "bash[$w,$N1H]: step end denied" 2 "$(polx $w Bash 'source ~/.n1/preamble.sh; n1_step_end ci 13 success')"
        eq "bash[$w,$N1H]: step begin denied" 2 "$(polx $w Bash 'n1_step_begin local-testing 11')"
        eq "bash[$w,$N1H]: run pointer clear denied" 2 "$(polx $w Bash 'n1_active_run_clear')"
        eq "bash[$w,$N1H]: merge denied" 2 "$(polx $w Bash 'gh pr merge 7 --squash')"
        eq "bash[$w,$N1H]: default-branch push denied" 2 "$(polx $w Bash 'git push origin HEAD:main')"
        eq "bash[$w,$N1H]: worktree remove denied" 2 "$(polx $w Bash 'git worktree remove /x')"
    done
        for c in 'git push' 'git push -u origin feat/x' 'gh pr create --fill' 'gh pr comment 7 -b x'; do
        eq "bash[local-testing-worker,$N1H]: '$c' denied" 2 "$(polx n1:local-testing-worker Bash "$c")"
    done
    eq "bash[ci-worker,$N1H]: feature-branch push allowed" 0 "$(polx n1:ci-worker Bash 'git push')"
    eq "bash[ci-worker,$N1H]: explicit feature push allowed" 0 "$(polx n1:ci-worker Bash 'git push -u origin feat/x')"
    eq "bash[ci-worker,$N1H]: CI log read allowed" 0 "$(polx n1:ci-worker Bash 'gh run view 5 --log-failed')"
done
N1H=; NH=
# outside any run scope the workers are still gated (gated_worker)
for w in n1:ci-worker n1:local-testing-worker; do
    eq "bash[$w,no run]: merge denied" 2 "$(polx $w Bash 'gh pr merge 7 --squash')"
    eq "bash[$w,no run]: default-branch push denied" 2 "$(polx $w Bash 'git push origin HEAD:main')"
done
eq "bash[ci-worker,no run]: feature push allowed" 0 "$(polx n1:ci-worker Bash 'git push -u origin feat/x')"

# 4. Persona contract
CW=agents/ci-worker.md; LW=agents/local-testing-worker.md
for f in $CW $LW; do
    has "$f: sonnet model" "$f" '^model: sonnet$'
    lacks "$f: no tools list (inherits dynamic MCP)" "$f" '^tools:'
    has "$f: foreground wait (N1-300)" "$f" 'never end your turn while a dispatched persona has no final report'
    has "$f: no step markers" "$f" 'no `n1_step_begin` or `n1_step_end`'
    has "$f: pre-side-effect prompt stops" "$f" 'reason: prompt: <the question, verbatim>'
    lacks "$f: no host tool names" "$f" 'SendMessage|AskUserQuestion|ToolSearch|spawn_agent|Agent tool'
done
has "ci-worker: dispatch list" $CW '^- Dispatch only developer and tech-writer '
has "ci-worker: reads n1-ci from files" $CW 'skills/n1-ci/SKILL.md'
for c in ci-escalate ci-low-confidence ci-not-branch-caused ci-cap-exhausted ci-pending-budget; do has "ci-worker: class $c" $CW "\`$c\`"; done
has "$CW: stop path wins over question classes" $CW 'stop path wins over § Question'
has "$LW: stop path wins over question classes" $LW 'stop path wins over § Question'
has "local-testing-worker: complete result carries outcome" $LW '^outcome: <the step end outcome>$'
has "local-testing-worker: dispatch list" $LW '^- Dispatch only local-test-planner and developer;'
has "local-testing-worker: runs the run procedure in Worker mode" $LW 'local-testing-run.md.*Worker mode'
for c in lt-env-failure lt-fix-exhausted; do has "local-testing-worker: class $c" $LW "\`$c\`"; done

# 5. Dispatch procedure and ci wiring (AC1, AC3, AC4, AC5)
D=skills/n1-start/procedures/step-worker-dispatch.md; CI=skills/n1-start/steps/ci.md
has "dispatch: ci result ends the step" $D 'n1_step_end "ci" 13 "\$O"'
has "dispatch: lt result ends the step" $D 'n1_step_end "local-testing" 11 "\$O"'
has "dispatch: question parsed" $D 'n1_sw_question'
has "dispatch: resume same worker with the answer" $D 'answer: <n> <text>'
has "dispatch: resume via host message mechanism" $D 'host message mechanism'
has "dispatch: foreground wait" $D 'Wait Contract'
has "dispatch: headless guard applied in the orchestrator" $D 'N1_HEADLESS=1.*§ Headless Guard'
has "dispatch: lt cap uses the Autonomy Gate" $D 'lt-fix-exhausted.*§ Autonomy Gate'
has "dispatch: Recommended label only from the file" $D '\(Recommended\)` only on the option'
has "dispatch: lt-fix-exhausted label only without a stop list" $D 'lt-fix-exhausted.*stop_list:none.*evidence'
has "dispatch: round-trip cap" $D 'third round trip'
has "dispatch: unknown result falls back inline" $D 'returned no status; ran <step> inline'
lacks "dispatch: no host tool names" $D 'SendMessage|AskUserQuestion|ToolSearch|spawn_agent'
has "ci: entry in begin fence" $CI 'n1_sw_entry ci "\$PR"'
has "ci: dispatch reference" $CI 'procedures/step-worker-dispatch.md'
has "ci: inline fallback keeps n1-ci" $CI 'n1:n1-ci'
has "ci: no-pr goes inline" $CI 'ci-worker:no-pr'
has "ci: prMode skip guard kept" $CI '\*\*If `prMode` is `"skip"`\*\*'
eq "ci: at most 2 bash fences in the step" yes "$([ "$(grep -c '^```bash' $CI)" -le 2 ] && echo yes || echo no)"
has "ci: end block never after a worker result" $CI 'never after a worker result'
has "dispatch: verbatim no-recommendation sentence" $D 'No recommendation\. The options are equivalent given the available evidence; select based on team preference\.'
has "dispatch: headless escalation includes the run-ending recommended branch" $D 'including the guard.s branch for a recommended option that ends the run'

# TQ-1: run the Result fences of the dispatch procedure with n1_step_end stubbed
fence() { awk -v h="## $1" '$0==h{s=1;next} /^## /{s=0} s&&/^```bash/{f=1;next} s&&/^```/{f=0} s&&f' "$REPO/$D" | grep -v '^source ~/.n1/preamble.sh' | sed 's/<ID>/T-1/'; }
runfence() { # <ci|local-testing> — prints the fence output and the recorded n1_step_end arguments
    (cd "$WT" && export HOME="$T/home" N1_ROOT="$REPO" N1_HOME="$T/n1" \
        && source "$REPO/lib/preamble.sh" >/dev/null 2>&1; n1_step_end() { echo "END $*"; }; eval "$(fence "$1")")
}
S=ci; for step in ci local-testing; do
    case $step in ci) S=ci; ID_N=13;; *) S=lt; ID_N=11;; esac
    printf 'status: complete\noutcome: success\nmetadata: {"a":1}\n' > "$MEM/$S-result.md"
    eq "fence $step: complete records id, outcome and metadata" "END $step $ID_N success {\"a\":1}" "$(runfence $step | grep '^END')"
    printf 'status: stopped\nreason: gave up\n' > "$MEM/$S-result.md"
    eq "fence $step: stopped ends the step failed" "END $step $ID_N failed" "$(runfence $step | grep '^END')"
    printf 'status: question\nreason: -\n' > "$MEM/$S-result.md"
    printf '%s\n' "class: $S-escalate" 'stop_list: none' 'question: q' 'option: a' > "$MEM/$S-question.md"
    [ $S = lt ] && printf '%s\n' 'class: lt-env-failure' 'stop_list: none' 'question: q' 'option: a' > "$MEM/$S-question.md"
    OUT=$(runfence $step)
    eq "fence $step: question prints the question and does not end the step" "no yes" "$(grep -q '^END' <<<"$OUT" && echo yes || echo no) $(grep -q '^question:q' <<<"$OUT" && echo yes || echo no)"
done
rm -f "$MEM"/*-result.md "$MEM"/*-question.md

# 6. local-testing wiring (AC1, AC5)
LT=skills/n1-start/steps/local-testing.md; LTR=skills/n1-start/procedures/local-testing-run.md
has "lt: begin fence enters the worker when live" $LT '\[ "\$MODE" = live \]'
eq "lt: entry called in begin fence and offer path" 2 "$(grep -c 'else n1_sw_entry lt; fi' $LT)"
has "lt: dispatch reference" $LT 'procedures/step-worker-dispatch.md'
has "lt: inline fallback keeps the run procedure" $LT 'read `procedures/local-testing-run.md`'
has "lt: QA runner block marked inline fallback" $LT 'QA runner commands \(inline fallback only\)'
has "lt: step end never after a worker result" $LT 'never after a worker result'
has "lt-run: Worker mode paragraph" $LTR '^\*\*Worker mode \(N1-645\)\.\*\*'
has "lt-run: Worker mode writes lt-result.md" $LTR 'lt-result.md'
has "lt-run: Worker mode prompts become question files" $LTR 'question file'
has "lt: begin fence that ended the step skips to Step 10" $LT 'if it ended the step .*skip to Step 10'
lacks "lt: no unconditional jump to Gates passed" $LT 'With mode `live`, this fence'
has "lt-run: pre-side-effect prompts follow persona Boundaries" $LTR 'except before any side effect: `agents/local-testing-worker.md` § Boundaries'
# begin fence of the default live path: begin + auto-skip + entry in one call
BEGIN=$(awk '/^```bash/{n++} n==1' $LT)
eq "lt: one fence holds begin, auto-skip and entry" "1 1 1" "$(grep -c 'n1_step_begin "local-testing" 11' <<<"$BEGIN") $(grep -c 'n1_sw_lt_auto_skip' <<<"$BEGIN") $(grep -c 'n1_sw_entry lt' <<<"$BEGIN")"

# --- end of checks ---
exit "$FAIL"
