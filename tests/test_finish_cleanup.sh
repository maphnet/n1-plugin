#!/usr/bin/env bash
# tests/test_finish_cleanup.sh
# N1-112: n1_finish_cleanup removes the linked worktree BEFORE deleting the branch; external
# worktrees only when clean and merged (never forced); worktree.cleanup=manual keeps both.
# Run: bash tests/test_finish_cleanup.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
assert_prefix() { case "$3" in "$2"*) pass "$1" ;; *) fail "$1" "$2*" "$3" ;; esac; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

M="$T/main"
git init -q -b main "$M"
git -C "$M" commit -q --allow-empty -m init

# new_wt <path> <branch>: linked worktree on a new <branch> with one commit.
new_wt() {
    git -C "$M" worktree add -q -b "$2" "$1" main
    echo "$2" > "$1/f-$2"; git -C "$1" add . ; git -C "$1" commit -q -m "$2"
}
# run <dir> <branch> <mode> <oid>: helper output, run from <dir> in a subshell.
run() { (cd "$1" && n1_finish_cleanup "$2" "$3" "$4" main) | paste -sd, -; }
has_branch() { git -C "$M" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo yes || echo no; }
has_dir() { [ -d "$1" ] && echo yes || echo no; }
tip() { git -C "$M" rev-parse "$1"; }

# C1: external, clean, merged (merge commit). The branch is checked out in the worktree, so
# "worktree:none,branch:deleted" proves the worktree was removed BEFORE git branch -d ran.
new_wt "$T/ext1" f1; git -C "$M" merge -q --no-ff -m m1 f1
assert_eq "C1: external clean merged -> removed + deleted" "worktree:removed,branch:deleted" "$(run "$T/ext1" f1 after-merge "$(tip f1)")"
assert_eq "C1: worktree dir gone" no "$(has_dir "$T/ext1")"
assert_eq "C1: branch gone" no "$(has_branch f1)"

# C2: external with uncommitted changes -> kept, never forced.
new_wt "$T/ext2" f2; git -C "$M" merge -q --no-ff -m m2 f2; echo dirty > "$T/ext2/dirty"
assert_eq "C2: dirty external kept" "worktree:kept (dirty),branch:kept (worktree kept)" "$(run "$T/ext2" f2 after-merge "$(tip f2)")"
assert_eq "C2: dir kept" yes "$(has_dir "$T/ext2")"
assert_eq "C2: branch kept" yes "$(has_branch f2)"

# C3: external with a local commit not in the merged PR head -> kept.
new_wt "$T/ext3" f3; OID3=$(tip f3)
echo more > "$T/ext3/more"; git -C "$T/ext3" add . ; git -C "$T/ext3" commit -q -m extra
assert_eq "C3: unmerged external kept" "worktree:kept (unmerged),branch:kept (worktree kept)" "$(run "$T/ext3" f3 after-merge "$OID3")"
assert_eq "C3: dir kept" yes "$(has_dir "$T/ext3")"

# C4: worktree.cleanup=manual keeps both.
new_wt "$T/ext4" f4; git -C "$M" merge -q --no-ff -m m4 f4
assert_eq "C4: manual keeps both" "worktree:kept (manual),branch:kept (manual)" "$(run "$T/ext4" f4 manual "$(tip f4)")"
assert_eq "C4: dir kept" yes "$(has_dir "$T/ext4")"
assert_eq "C4: branch kept" yes "$(has_branch f4)"

# C5: N1-managed worktree (under n1_worktree_root) is force-removed even when dirty; branch deleted too.
WT5="$M/$(n1_worktree_root)/N1-5"
new_wt "$WT5" f5; git -C "$M" merge -q --no-ff -m m5 f5; echo dirty > "$WT5/dirty"
assert_eq "C5: N1-managed removed + branch deleted" "worktree:removed,branch:deleted" "$(run "$WT5" f5 after-merge "$(tip f5)")"
assert_eq "C5: dir gone" no "$(has_dir "$WT5")"

# C6: squash merge: -d refuses, tip == merged PR head -> -D fallback.
new_wt "$T/ext6" f6; OID6=$(tip f6)
git -C "$M" merge -q --squash f6 >/dev/null; git -C "$M" commit -q -m sq6
assert_eq "C6: squash, tip == PR head -> deleted" "worktree:removed,branch:deleted" "$(run "$T/ext6" f6 after-merge "$OID6")"
assert_eq "C6: branch gone" no "$(has_branch f6)"

# C7: squash merge, PR head is a later commit than the local tip -> worktree removed, branch kept.
new_wt "$T/ext7" f7
OID7=$(git -C "$M" commit-tree -p f7 -m later "$(git -C "$M" rev-parse 'f7^{tree}')")
git -C "$M" merge -q --squash f7 >/dev/null; git -C "$M" commit -q -m sq7
assert_eq "C7: tip != PR head -> branch kept" "worktree:removed,branch:kept (not merged)" "$(run "$T/ext7" f7 after-merge "$OID7")"
assert_eq "C7: branch kept" yes "$(has_branch f7)"

# C8: local-merge path (empty oid): merged proof is ancestry of <defaultBranch>.
new_wt "$T/ext8" f8; git -C "$M" merge -q --no-ff -m m8 f8
assert_eq "C8: local merge external removed" "worktree:removed,branch:deleted" "$(run "$T/ext8" f8 after-merge "")"

# C9: removal failure (locked worktree) is reported, rc 0, branch kept.
new_wt "$T/ext9" f9; git -C "$M" merge -q --no-ff -m m9 f9; git -C "$M" worktree lock "$T/ext9"
OUT9=$(run "$T/ext9" f9 after-merge "$(tip f9)"); RC9=$?
assert_prefix "C9: locked -> removal failed reported" "worktree:remove-failed (" "$OUT9"
assert_eq "C9: never non-zero" 0 "$RC9"
assert_eq "C9: branch kept" yes "$(has_branch f9)"

# C11: branch name differs from the checkout -> kept-other, own branch still deleted.
new_wt "$T/ext11" f11; git -C "$M" merge -q --no-ff -m m11 f11; git -C "$M" branch -q f11b; git -C "$M" merge -q f11b
assert_eq "C11: other ticket worktree untouched" "worktree:kept-other,branch:deleted" "$(run "$T/ext11" f11b after-merge "")"
assert_eq "C11: dir kept" yes "$(has_dir "$T/ext11")"

# C10: branch mode (plain checkout on the feature branch): switch to default, delete; re-run no-ops.
git -C "$M" checkout -q -b f10; git -C "$M" commit -q --allow-empty -m f10
git -C "$M" checkout -q main; git -C "$M" merge -q --no-ff -m m10 f10; git -C "$M" checkout -q f10
assert_eq "C10: branch mode deleted" "worktree:none,branch:deleted" "$(git -C "$M" checkout -q main; run "$M" f10 after-merge "$(tip f10)")"
assert_eq "C10: re-run is a no-op" "worktree:none,branch:none" "$(run "$M" f10 after-merge "")"

# C12: cwd ends in the main checkout after removal (no pipe/subshell), unchanged when kept.
new_wt "$T/ext12" f12; git -C "$M" merge -q --no-ff -m m12 f12
cd "$T/ext12"; n1_finish_cleanup f12 after-merge "$(tip f12)" main >/dev/null; assert_eq "C12: cwd is main after removal" "$(cd "$M" && pwd -P)" "$(pwd -P)"
new_wt "$T/ext12b" f12b; echo d > "$T/ext12b/d"
cd "$T/ext12b"; n1_finish_cleanup f12b after-merge "" main >/dev/null; assert_eq "C12: cwd unchanged when kept" "$(cd "$T/ext12b" && pwd -P)" "$(pwd -P)"
cd "$T"

# C13: modes: empty -> after-merge, after-pr removes, unknown -> manual.
new_wt "$T/ext13" f13; git -C "$M" merge -q --no-ff -m m13 f13
assert_eq "C13: empty mode defaults to after-merge" "worktree:removed,branch:deleted" "$(run "$T/ext13" f13 "" "$(tip f13)")"
new_wt "$T/ext14" f14; git -C "$M" merge -q --no-ff -m m14 f14
assert_eq "C14: after-pr removes" "worktree:removed,branch:deleted" "$(run "$T/ext14" f14 after-pr "$(tip f14)")"
new_wt "$T/ext15" f15; git -C "$M" merge -q --no-ff -m m15 f15
assert_eq "C15: unknown mode keeps both" "worktree:kept (manual),branch:kept (manual)" "$(run "$T/ext15" f15 bogus "$(tip f15)")"

# C16: manual on a plain checkout keeps the branch.
git -C "$M" checkout -q -b f16; git -C "$M" commit -q --allow-empty -m f16
git -C "$M" checkout -q main; git -C "$M" merge -q --no-ff -m m16 f16
assert_eq "C16: plain checkout manual keeps branch" "worktree:none,branch:kept (manual)" "$(run "$M" f16 manual "")"
assert_eq "C16: branch kept" yes "$(has_branch f16)"

# C17: N1-managed worktree with unmerged commits and no OID: force-removed, branch kept.
WT17="$M/$(n1_worktree_root)/N1-17"; new_wt "$WT17" f17
assert_eq "C17: N1-managed unmerged, no oid" "worktree:removed,branch:kept (not merged)" "$(run "$WT17" f17 after-merge "")"

# C18: gitignored files keep an external worktree (never silently deleted).
new_wt "$T/ext18" f18; git -C "$M" merge -q --no-ff -m m18 f18
echo ".env" > "$T/ext18/.gitignore"; git -C "$T/ext18" add .gitignore; git -C "$T/ext18" commit -q -m ign
git -C "$M" merge -q f18; echo secret > "$T/ext18/.env"
assert_eq "C18: ignored files keep worktree" "worktree:kept (ignored files),branch:kept (worktree kept)" "$(run "$T/ext18" f18 after-merge "$(tip f18)")"
assert_eq "C18: .env intact" yes "$(has_dir "$T/ext18")"

# C19: separate-git-dir main checkout: branch ops hit the right repo.
git init -q -b main --separate-git-dir "$T/sep.git" "$T/sepmain"
git -C "$T/sepmain" commit -q --allow-empty -m init
git -C "$T/sepmain" worktree add -q -b f19 "$T/ext19" main; git -C "$T/ext19" commit -q --allow-empty -m f19
git -C "$T/sepmain" merge -q --no-ff -m m19 f19
assert_eq "C19: separate-git-dir removed + deleted" "worktree:removed,branch:deleted" "$( (cd "$T/ext19" && n1_finish_cleanup f19 after-merge "" main) | paste -sd, -)"

# C20: never kills a set -e caller; always prints tokens (too few args, outside a repo).
OUT20=$(bash -c 'set -euo pipefail; source "$1/lib/config.sh"; cd "$2"; n1_finish_cleanup; echo rc:$?' _ "$SCRIPT_DIR/.." "$T" | paste -sd, -)
assert_eq "C20: outside a repo, no args" "worktree:none,branch:none,rc:0" "$OUT20"
OUT20=$(bash -c 'set -euo pipefail; source "$1/lib/config.sh"; cd "$2"; n1_finish_cleanup f1; echo rc:$?' _ "$SCRIPT_DIR/.." "$M" | paste -sd, -)
assert_eq "C20: in a repo, too few args" "worktree:none,branch:none,rc:0" "$OUT20"

# Static: Step 6 delegates to the helper and no longer exempts external worktrees.
R="$SCRIPT_DIR/.."; STEP6="$R/skills/n1-finish/steps/06-cleanup.md"
yn() { "$@" && echo yes || echo no; }
assert_eq "S1: step 6 calls n1_finish_cleanup" yes "$(yn grep -qF 'n1_finish_cleanup "$HR"' "$STEP6")"
assert_eq "S2: step 6 has no inline worktree remove / -D" no "$(yn grep -qE 'git worktree remove|git branch -D' "$STEP6")"
assert_eq "S3: step 6 fetches headRefOid in the cleanup block" yes "$(yn grep -qF 'headRefOid' "$STEP6")"
assert_eq "S4: architecture.md drops external exemption" no "$(yn grep -qF 'Does not apply to external worktrees' "$R/references/architecture.md")"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
