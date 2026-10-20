#!/usr/bin/env bash
# N1-110 (restored in N1-112): n1-finish 06-cleanup.md block: memory rewrite idempotent, Ledger kept, worktree tokens. Throwaway repo.
# Decision Ledger. Runs in a throwaway repo on the default branch, so no worktree/branch side effects.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
unset N1_RUN_ID N1_SESSION_ID N1_QUEUE_RUN_ID

SNIP=$(awk '/^```bash/{b=1;next} b&&/^```/{exit} b' skills/n1-finish/steps/06-cleanup.md \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e 's/<ID>/T-1/' -e 's/<defaultBranch>/main/' -e 's/<0|1>/1/' -e 's/<PR number; empty on local merge>//' -e 's/<headRefName>/${HR_TEST:-main}/' \
          -e 's/^<the rendered ## Finish block from item 4>$/## Finish\n- **Merged:** abc1234/')

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/memory/T-1" "$T/repo"
git -C "$T/repo" init -q -b main
git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m init
OV="$T/home/memory/T-1/overview.md"
printf -- '---\nstep: finish\n---\n# T-1\n## Pending\n- pr_url: x\n## Finish\n- **Merged:** old\n## Decision Ledger\n| a | b |\n' > "$OV"

run() { OUT=$(cd "$T/repo" && N1_ROOT="$REPO" N1_HOME="$T/home" bash -c "$SNIP" 2>&1); }
chk() { # <label> <cond-exit>
    if [ "$2" = 0 ]; then ok "$1"; else no "$1"; fi
}
for pass in 1 2; do
    run
    grep -q '^## Pending' "$OV"; chk "run $pass: Pending removed" $((! $? ))
    chk "run $pass: Finish exactly once" $([ "$(grep -c '^## Finish' "$OV")" = 1 ]; echo $?)
    grep -q 'Merged:\*\* abc1234' "$OV"; chk "run $pass: new Finish content" $?
    grep -q '^## Decision Ledger' "$OV" && grep -q '^| a | b |' "$OV"; chk "run $pass: Ledger survives" $?
    grep -q '^step: done' "$OV"; chk "run $pass: step done" $?
    grep -q 'memory:done' <<<"$OUT"; chk "run $pass: memory status printed" $?
    grep -q 'branch:none' <<<"$OUT" && grep -q 'worktree:none' <<<"$OUT"; chk "run $pass: branch/worktree status printed" $?
done
chk "no leftover temp files" $([ -z "$(ls "$T/home/memory/T-1" | grep -v '^overview.md$')" ]; echo $?)

# Linked worktree under the N1 worktree root: always removed after a successful finish.
wt() { # <name>
    echo '{}' > "$T/home/config.json"
    git -C "$T/repo" worktree add -q -b "$1" "$T/repo/.claude/worktrees/$1"
    OUT=$(cd "$T/repo/.claude/worktrees/$1" && HR_TEST="${HR:-$1}" N1_ROOT="$REPO" N1_HOME="$T/home" bash -c "$SNIP" 2>&1)
}
wt feat
grep -qx 'worktree:removed' <<<"$OUT"; chk "worktree: removed status" $?
chk "worktree: directory gone" $([ ! -d "$T/repo/.claude/worktrees/feat" ]; echo $?)
grep -qx 'branch:deleted' <<<"$OUT"; chk "worktree: branch status printed" $?
# Linked worktree of another ticket (branch differs from the finished PR's head): untouched.
HR=other-pr wt mine; HR=
grep -qx 'worktree:kept-other' <<<"$OUT"; chk "other ticket worktree: kept-other status" $?
chk "other ticket worktree: directory stays" $([ -d "$T/repo/.claude/worktrees/mine" ]; echo $?)
chk "other ticket worktree: its branch stays" $(git -C "$T/repo" rev-parse --verify -q mine >/dev/null; echo $?)
# Invalid head ref is rejected before anything runs.
OUT=$(cd "$T/repo" && HR_TEST='a;b' N1_ROOT="$REPO" N1_HOME="$T/home" bash -c "$SNIP" 2>&1)
grep -q 'headref:invalid' <<<"$OUT"; chk "invalid head ref rejected" $?
# Empty ID must not abort cleanup; memory block is skipped.
OUT=$(cd "$T/repo" && N1_ROOT="$REPO" N1_HOME="$T/home" bash -c "${SNIP//T-1/}" 2>&1)
grep -q 'memory:none' <<<"$OUT" && grep -q 'branch:none' <<<"$OUT"; chk "empty ID: cleanup continues without memory" $?
exit $FAIL
