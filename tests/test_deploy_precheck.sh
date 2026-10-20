#!/usr/bin/env bash
# tests/test_deploy_precheck.sh -- N1-113: n1-finish skips the deploy watch only when no workflow can fire on push.
# Run: bash tests/test_deploy_precheck.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIP=$(awk '/^```bash/{b=1;next} b&&/^```/{exit} b' "$REPO/skills/n1-finish/steps/03-deploy.md")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL+1)); fi; }
pc() { # <workflowName> -> precheck token, run in $T/r
    (cd "$T/r" && bash -c "${SNIP//<workflowName>/$1}" 2>/dev/null)
}
git init -q "$T/r"
chk "no workflows dir -> none" "precheck:none" "$(pc '')"
chk "workflowName set -> watch" "precheck:watch" "$(pc 'deploy.yml')"
mkdir -p "$T/r/.github/workflows"
printf 'on: [pull_request]\njobs: {}\n' > "$T/r/.github/workflows/ci.yml"
chk "pull_request only -> none" "precheck:none" "$(pc '')"
printf 'on:\n  push:\n    branches: [main]\n' > "$T/r/.github/workflows/deploy.yaml"
chk "push trigger -> watch" "precheck:watch" "$(pc '')"
rm "$T/r/.github/workflows/deploy.yaml"; printf 'on:\n  workflow_run:\n    workflows: [CI]\n' > "$T/r/.github/workflows/cd.yml"
chk "workflow_run trigger -> watch" "precheck:watch" "$(pc '')"
rm "$T/r/.github/workflows/"*; chk "empty workflows dir -> watch (unknown)" "precheck:watch" "$(pc '')"
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
