#!/usr/bin/env bash
# tests/test_qa_verify_env_isolation.sh — verifyGate re-runs only QA-named test commands, each in an env -i shell,
# and flags a reported pass that a named command contradicts.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_MD="$REPO_ROOT/skills/n1-start/steps/qa.md"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }

# Guard against regressing to the masking `eval "$RUNNER_CMD"` form.
if grep -q 'eval "\$RUNNER_CMD"' "$QA_MD"; then
  echo "FAIL: qa.md still uses eval \"\$RUNNER_CMD\" (env leak reintroduced)"; FAIL=$((FAIL+1))
else
  echo "PASS: qa.md does not use eval \"\$RUNNER_CMD\""; PASS=$((PASS+1))
fi
if grep -q 'env -i HOME="\$HOME" PATH="\$PATH" bash -c "\$RUNNER_CMD"' "$QA_MD"; then
  echo "PASS: qa.md runs RUNNER_CMD via env -i isolated shell"; PASS=$((PASS+1))
else
  echo "FAIL: qa.md does not run RUNNER_CMD via env -i isolated shell"; FAIL=$((FAIL+1))
fi
# N1-320: the gate no longer re-runs the full-suite Runner command.
if grep -q 'grep "^Runner command:"' "$QA_MD"; then
  echo "FAIL: qa.md verifyGate still re-runs the Runner command"; FAIL=$((FAIL+1))
else
  echo "PASS: qa.md verifyGate does not re-run the Runner command"; PASS=$((PASS+1))
fi

# Mechanism check: the exact isolation snippet used in qa.md strips ambient N1 vars.
export N1_RUN_ID="run-abc" N1_SESSION_ID="sess-1" ID="NP-238"
OUT=$(env -i HOME="$HOME" PATH="$PATH" bash -c 'echo "${N1_RUN_ID:-}${N1_SESSION_ID:-}${ID:-}"')
assert_eq "isolated shell sees no ambient N1_RUN_ID/N1_SESSION_ID/ID" "" "$OUT"

# Execute the real gate block from qa.md (VCMDS= ... fi) against fixture qa.md files.
GATE=$(awk '/^VCMDS=/{p=1} p{print} p&&/^fi$/{exit}' "$QA_MD")
assert_eq "qa.md has an extractable verifyGate block" "1" "$([ -n "$GATE" ] && echo 1 || echo 0)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
BT='`'
run_gate() { # <case-dir> -> prints QA_DEGRADED; key decisions land in <case-dir>/kd
  ( set +e +u +o pipefail  # skill snippets run without errexit/pipefail; an empty VCMDS grep must not abort
    QD="$1"; unset QA_DEGRADED
    n1_append_key_decision() { echo "$2" >> "$QD/kd"; }
    n1_write_frontmatter() { :; }
    source "$REPO_ROOT/lib/breakcheck.sh"
    eval "$GATE"
    echo "${QA_DEGRADED:-0}" )
}
# Case 1: reported pass, a named command fails. The first command reads stdin: without </dev/null it would
# swallow the remaining commands and the failing one would never run.
mkdir -p "$T/c1"; printf '%s\n' "Exit code: 0" "New test: reads_stdin | ${BT}cat > /dev/null; true${BT}" "Fixed test: tests/test_x.sh | ${BT}false${BT}" > "$T/c1/qa.md"
assert_eq "reported pass + failing named test -> degraded" "1" "$(run_gate "$T/c1")"
assert_eq "mismatch recorded in key decisions" "1" "$(grep -c 'QA verifyGate mismatch' "$T/c1/kd" || true)"
# Case 2: reported pass, all named commands pass; ambient N1 vars are not visible to them.
mkdir -p "$T/c2"; printf '%s\n' "Exit code: 0" "Regression test: r | ${BT}[ -z \"\${N1_RUN_ID:-}\" ]${BT}" "New test: n | ${BT}true${BT}" > "$T/c2/qa.md"
assert_eq "reported pass + passing isolated named tests -> not degraded" "0" "$(run_gate "$T/c2")"
# Case 3: no named test lines -> skipped, not degraded, nothing run.
mkdir -p "$T/c3"; printf '%s\n' "Runner command: ${BT}false${BT}" "Exit code: 0" > "$T/c3/qa.md"
assert_eq "no named tests -> not degraded" "0" "$(run_gate "$T/c3")"
assert_eq "no named tests -> skip recorded" "1" "$(grep -c 'QA verifyGate skipped' "$T/c3/kd" || true)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
