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

# --- end of checks ---
exit "$FAIL"
