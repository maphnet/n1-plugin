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

# 3. Hook boundaries (AC6): spawn allowlist, step markers, push and merge
polx() { local rc=0; jq -cn --arg a "$1" --arg t "$2" --arg c "$3" --arg w "$WT" \
    '{tool_name:$t,session_id:"s-sw",cwd:$w,tool_input:(if $t=="Bash" then {command:$c} else {subagent_type:$c} end),agent_type:$a}' \
    | env -u N1_QUEUE_RUN_ID -u N1_HEADLESS -u N1_HOME HOME="$T/home" ${N1H:+N1_HEADLESS=$N1H} ${NH:+N1_HOME=$NH} python3 hooks/enforce-agent-policy.py "${CFG:-}" "$REPO" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
NH="$T/nh"; mkdir -p "$NH"; echo '{"ticketId":"T-1"}' > "$NH/active-run.s-sw.json"; CFG=
for N1H in "" 1; do
    for tool in Agent Task; do
        eq "spawn[$tool,$N1H]: ci-worker -> developer allowed" 0 "$(polx n1:ci-worker $tool n1:developer)"
        for p in general-purpose n1:local-test-planner n1:tech-writer n1:ci-worker n1:tail-worker; do
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

# --- end of checks ---
exit "$FAIL"
