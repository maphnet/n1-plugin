#!/usr/bin/env bash
# N1-476: lib/pr-step.sh runs the pr step's pre-PR gate, entry and outcome blocks; pr.md's fences call them.
# Also guards the hook text-scan: no step lib wraps a push, PR-create, merge or gh api command.
# Run: bash tests/test_pr_step_lib.sh
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/pr-step.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID
export N1_HOME="$T/home" ID="PR-1" N1_SESSION_ID=test-session
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM/telemetry"; echo '{}' > "$N1_HOME/config.json"
G="$T/g"; git init -q -b feat/x "$G"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$G" || exit 1

# --- hook text-scan guard (hooks/enforce-agent-policy.py merge_deny sees only visible Bash text) ---
# Comment lines are skipped: lib headers name n1_step_begin/n1_step_end to say they are never called.
LIBS=("$REPO_ROOT"/lib/*-step.sh "$REPO_ROOT/lib/analysis.sh")
eq "guard: no step lib wraps push/PR-create/merge/gh api" "" "$(grep -nE 'gh pr (create|merge)|git push|gh api' "${LIBS[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
eq "guard: no step lib calls n1_step_begin/n1_step_end" "" "$(grep -nE 'n1_step_(begin|end)' "${LIBS[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"

# --- n1_pr_gate ---
printf -- '---\n---\n' > "$MEM/overview.md"
n1_review_artifacts_ok() { echo R1; return 0; }
eq "gate: artifacts ok -> rc 0" "PRE_PR_GATE=0 R1 PRE_PR_REVIEW_CYCLE=0/3" "$(n1_pr_gate)"
n1_review_artifacts_ok() { echo R1; return 1; }
echo stale > "$MEM/fix.diff"
eq "gate: no review -> rc 1" "PRE_PR_GATE=1 R1 PRE_PR_REVIEW_CYCLE=0/3" "$(n1_pr_gate)"
eq "gate: rc 1 bumps pre_pr_review_cycle" "1" "$(n1_read_frontmatter "$MEM/overview.md" pre_pr_review_cycle)"
eq "gate: rc 1 empties fix.diff (full-scope review)" "0" "$(wc -c < "$MEM/fix.diff" | tr -d ' ')"
printf '### Verdict: FAIL\n' > "$MEM/review.md"
eq "gate: non-PASS verdict -> rc 2" "PRE_PR_GATE=2 R1 PRE_PR_REVIEW_CYCLE=1/3" "$(n1_pr_gate)"
rm -f "$MEM/review.md"

# --- n1_pr_entry ---
: > "$MEM/pr-result.md"; : > "$MEM/pr-report.md"
OUT=$(n1_pr_entry 2>&1)
has "entry: prints FIX_AUDIT" "$OUT" "FIX_AUDIT="
has "entry: clean tree routes to the worker" "$OUT" "route:worker"
has "entry: model line names the memory dir" "$OUT" "memory:$MEM n1_root:$N1_ROOT worktree:$G"
eq "entry: stale pr-result/pr-report removed" "no" "$([ -e "$MEM/pr-result.md" ] || [ -e "$MEM/pr-report.md" ] && echo yes || echo no)"
echo x > "$G/dirty"; has "entry: dirty tree routes inline" "$(n1_pr_entry 2>&1)" "route:inline"; rm -f "$G/dirty"

# --- n1_pr_outcome ---
OUT=$(n1_pr_outcome 2>&1); RC=$?
eq "outcome: missing implementation.md -> rc 1" "1" "$RC"
has "outcome: missing implementation.md message" "$OUT" "ERROR: implementation.md missing — cannot create PR"
printf '# impl\n' > "$MEM/implementation.md"
eq "outcome: implementation.md present -> rc 0" "0" "$(n1_pr_outcome >/dev/null 2>&1; echo $?)"

# --- step wiring ---
STEP="$REPO_ROOT/skills/n1-start/steps/pr.md"
fence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1" | sed '/^source /d'; }
rawfence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1"; }
for N in 1 2 4; do has "wiring: pr fence $N sources the lib" "$(rawfence "$STEP" $N)" 'source "$N1_ROOT/lib/pr-step.sh"'; done
eq "wiring: pr.md has 4 bash fences" "4" "$(grep -c '^```bash$' "$STEP")"
eq "wiring: fence 1 is the gate call" "n1_pr_gate" "$(fence "$STEP" 1)"
has "wiring: fence 2 begins the step" "$(fence "$STEP" 2)" $'n1_step_begin "pr" 12\nn1_pr_entry'
has "wiring: fence 3 post-condition stays inline" "$(fence "$STEP" 3)" 'MISSING=$(n1_review_check_run)'
has "wiring: fence 4 maps a failed outcome to a failed step" "$(fence "$STEP" 4)" 'n1_pr_outcome || { n1_step_end "pr" 12 failed; exit 1; }'
STEPS_END=""; n1_step_begin() { :; }; n1_step_end() { STEPS_END="$3"; echo "END=$3"; }
rm -f "$MEM/implementation.md"
OUT=$( eval "$(fence "$STEP" 4)" 2>&1 )
has "wiring: outcome fence ends failed without implementation.md" "$OUT" "END=failed"

exit $FAIL
