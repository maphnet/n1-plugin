#!/usr/bin/env bash
# tests/test_qa_verify_env_isolation.sh — verifyGate re-runs only QA-named test commands, each in an env -i shell,
# and flags a reported pass that a named command contradicts.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_MD="$REPO_ROOT/lib/qa-step.sh"   # N1-476: the verifyGate body lives in lib/qa-step.sh
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"; source "$QA_MD"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

# Guard against regressing to the masking `eval "$RUNNER_CMD"` form.
if grep -q 'eval "\$RUNNER_CMD"' "$QA_MD"; then
  echo "FAIL: lib/qa-step.sh still uses eval \"\$RUNNER_CMD\" (env leak reintroduced)"; FAIL=$((FAIL+1))
else
  echo "PASS: lib/qa-step.sh does not use eval \"\$RUNNER_CMD\""; PASS=$((PASS+1))
fi
if grep -q 'env -i HOME="\$HOME" PATH="\$PATH" bash -c "\$RUNNER_CMD"' "$QA_MD"; then
  echo "PASS: lib/qa-step.sh runs RUNNER_CMD via env -i isolated shell"; PASS=$((PASS+1))
else
  echo "FAIL: lib/qa-step.sh does not run RUNNER_CMD via env -i isolated shell"; FAIL=$((FAIL+1))
fi
# N1-320: the gate no longer re-runs the full-suite Runner command.
if grep -q 'grep "^Runner command:"' "$QA_MD"; then
  echo "FAIL: lib/qa-step.sh verifyGate still re-runs the Runner command"; FAIL=$((FAIL+1))
else
  echo "PASS: lib/qa-step.sh verifyGate does not re-run the Runner command"; PASS=$((PASS+1))
fi

# Mechanism check: the exact isolation snippet used in qa.md strips ambient N1 vars.
export N1_RUN_ID="run-abc" N1_SESSION_ID="sess-1" ID="NP-238"
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c 'echo "${N1_RUN_ID:-}${N1_SESSION_ID:-}${ID:-}"')
assert_eq "isolated shell sees no ambient N1_RUN_ID/N1_SESSION_ID/ID" "" "$OUT"

# Run the real verifyGate (n1_qa_verify) against fixture qa.md files.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BT='`'
run_gate() { # <case> -> prints QA_DEGRADED; key decisions land in <case-dir>/kd
  ( set +e +u +o pipefail  # skill snippets run without errexit/pipefail; an empty VCMDS grep must not abort
    export N1_HOME="$T/home" ID="$1"; QD="$N1_HOME/memory/$1"
    n1_append_key_decision() { echo "$2" >> "$QD/kd"; }
    n1_write_frontmatter() { :; }
    n1_qa_verify | sed -n 's/^QA_DEGRADED=//p' )
}
case_dir() { mkdir -p "$T/home/memory/$1"; echo "$T/home/memory/$1"; }
# Case 1: reported pass, a named command fails. The first command reads stdin: without </dev/null it would
# swallow the remaining commands and the failing one would never run.
C=$(case_dir c1); printf '%s\n' "### Evidence" "Exit code: 0" "New test: reads_stdin | ${BT}cat > /dev/null; true${BT}" "Fixed test: tests/test_x.sh | ${BT}false${BT}" > "$C/qa.md"
assert_eq "reported pass + failing named test -> degraded" "1" "$(run_gate c1)"
assert_eq "mismatch recorded in key decisions" "1" "$(grep -c 'QA verifyGate mismatch' "$C/kd" || true)"
# Case 2: reported pass, all named commands pass; ambient N1 vars are not visible to them.
C=$(case_dir c2); printf '%s\n' "### Evidence" "Exit code: 0" "Regression test: r | ${BT}[ -z \"\${N1_RUN_ID:-}\" ]${BT}" "New test: n | ${BT}true${BT}" > "$C/qa.md"
assert_eq "reported pass + passing isolated named tests -> not degraded" "0" "$(run_gate c2)"
# Case 3: no named test lines -> skipped, not degraded, nothing run.
C=$(case_dir c3); printf '%s\n' "### Evidence" "Runner command: ${BT}false${BT}" "Exit code: 0" > "$C/qa.md"
assert_eq "no named tests -> not degraded" "0" "$(run_gate c3)"
assert_eq "no named tests -> skip recorded" "1" "$(grep -c 'QA verifyGate skipped' "$C/kd" || true)"
# Case 4: Exit code line missing, a named command fails -> still degraded.
C=$(case_dir c4); printf '%s\n' "### Evidence" "Fixed test: tests/test_x.sh | ${BT}false${BT}" > "$C/qa.md"
assert_eq "missing Exit code + failing named test -> degraded" "1" "$(run_gate c4)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
