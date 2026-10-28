#!/usr/bin/env bash
# tests/test_deploy_precheck.sh -- N1-113: n1-finish skips the deploy watch only when no workflow can fire on push.
# Run: bash tests/test_deploy_precheck.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIP=$(awk '/^\*\*Pre-check/{p=1} p&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$REPO/skills/n1-finish/steps/03-deploy.md")
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL+1)); fi; }
git init -q "$T/r"; git -C "$T/r" config user.email t@t; git -C "$T/r" config user.name t
# N1-169: ugrep (Claude Code's grep function) unreliably matches a pattern with `(^|[^` (input-dependent); model it, exported into the snippet shell.
grep() { case "$*" in *'(^|[^'*) return 1 ;; *) command grep "$@" ;; esac; }
export -f grep
pcl() { # <workflowName> [sha] -> full precheck line, run in $T/r; sha defaults to HEAD
    local sha="${2:-$(git -C "$T/r" rev-parse HEAD 2>/dev/null)}" s="${SNIP//<workflowName>/$1}"
    (cd "$T/r" && bash -c "${s//<sha>/$sha}" 2>/dev/null)
}
pc() { local o; o=$(pcl "$@"); echo "${o%% *}"; } # first token only
W="$T/r/.github/workflows"
rw() { rm -rf "$W"; mkdir -p "$W"; }
cm() { git -C "$T/r" add -A; git -C "$T/r" commit -qm "$1" --allow-empty; }
cm base
chk "no workflows dir -> none" "precheck:none" "$(pc '')"
chk "no workflows dir -> count 0" "precheck:none 0" "$(pcl '')"
chk "workflowName set -> watch" "precheck:watch" "$(pc 'deploy.yml')"
mkdir -p "$W"; printf 'on: [pull_request]\njobs: {}\n' > "$W/ci.yml"; cm pr
chk "pull_request only -> none" "precheck:none" "$(pc '')"
chk "none carries workflow count" "precheck:none 1" "$(pcl '')"
printf 'on:\n  push:\n    branches: [main]\n' > "$W/deploy.yaml"; cm push
chk "push trigger -> watch" "precheck:watch" "$(pc '')"
rw; printf 'on:\n  workflow_run:\n    workflows: [CI]\n' > "$W/cd.yml"; cm wr
chk "workflow_run trigger -> watch" "precheck:watch" "$(pc '')"
rw; printf 'name: Deploy\non:\n  push:\n    branches: [main]\n  release:\n    types: [published]\n  workflow_dispatch:\n    inputs:\n      env:\n        required: false\n' > "$W/deploy.yml"; cm ticket
chk "N1-169 deploy.yml (push+release+dispatch) -> watch" "precheck:watch" "$(pc '')"
rw; printf 'on: [workflow_dispatch]\njobs:\n  t:\n    steps:\n      - run: echo pushed push_x\n' > "$W/a.yml"; cm lookalike
chk "pushed/push_x lookalikes only -> none" "precheck:none" "$(pc '')"
rw; printf 'on: push\n' > "$W/a.yml"; cm onpush
chk "on: push -> watch" "precheck:watch" "$(pc '')"
printf 'on: [push]\n' > "$W/a.yml"; cm list
chk "on: [push] -> watch" "precheck:watch" "$(pc '')"
rw; printf 'on: push\n' > "$W/a.yaml"; cm yaml
chk ".yaml file -> watch" "precheck:watch" "$(pc '')"
# Accepted false positive: any word 'push' counts (watch is the safe side).
rw; printf 'on: [workflow_dispatch]\njobs:\n  t:\n    steps:\n      - run: git push\n' > "$W/a.yml"; cm fp
chk "run: git push under manual trigger -> watch (accepted false positive)" "precheck:watch" "$(pc '')"
printf 'on: [workflow_dispatch]\n' > "$W/a.yml"; cm manual
chk "manual-only trigger -> none" "precheck:none" "$(pc '')"
MANUAL=$(git -C "$T/r" rev-parse HEAD)
# Merge SHA is inspected, not the checkout.
printf 'on: push\n' > "$W/a.yml"; cm pushlater; PUSHSHA=$(git -C "$T/r" rev-parse HEAD)
chk "checkout has push, merge SHA manual-only -> none" "precheck:none" "$(pc '' "$MANUAL")"
rw; cm cleared
chk "checkout has no workflows, merge SHA has push -> watch" "precheck:watch" "$(pc '' "$PUSHSHA")"
chk "SHA missing -> watch" "precheck:watch" "$(pc '' 0123456789abcdef0123456789abcdef01234567)"
chk "no workflows at SHA -> none" "precheck:none" "$(pc '')"
# N1-169: ban the ugrep-unsafe `(^|[^` construct in shipped text. SKILL.md look() keeps the literal for bash `=~` and jq (not grep), so it is excluded here and checked below.
command grep -rnF '(^|[^' "$REPO/skills" "$REPO/lib" --exclude=SKILL.md >/dev/null 2>&1; chk "no (^|[^ in skills/ lib/ (grep exit 1 = no match)" "1" "$?"
chk "SKILL.md: no grep line carries (^|[^" "" "$(command grep -rF '(^|[^' "$REPO/skills" --include=SKILL.md | command grep -w grep)"
chk "n1-finish look() uses =~, not grep -qiE" "0" "$(command grep -c 'grep -qiE "\$X"' "$REPO/skills/n1-finish/SKILL.md")"
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
