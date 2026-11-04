#!/usr/bin/env bash
# tests/test_clean_ticket.sh — N1-339: n1_clean_ticket (ticket-keyed cleanup) and n1-clean wiring.
# Run: bash tests/test_clean_ticket.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; R="$SCRIPT_DIR/.."
source "$R/lib/config.sh"
source "$R/lib/telemetry.sh"
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }
yn() { "$@" && echo yes || echo no; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset ORCA_CLI_COMMAND N1_RUN_ID N1_QUEUE_DIR N1_QUEUE_RUN_ID
mkdir -p "$T/bin" "$N1_HOME/memory"
# gh stub: logs argv, prints $GH_TSV (state, headRefName, headRefOid, baseRefName). Never left empty in a case
# that reaches gh (an empty answer triggers the 2s/4s retry backoff).
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"; printf '%s\n' "${GH_TSV:-}"
EOF
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" GH_CALLS="$T/gh.calls"

M="$T/main"; git init -q -b main "$M"; git -C "$M" commit -q --allow-empty -m init
URL=https://github.com/o/r/pull/7
ov() { mkdir -p "$N1_HOME/memory/$1"; printf -- '---\nstep: pr\n---\n# %s\n## Pending\npr_url: %s\n' "$1" "${2-$URL}" > "$N1_HOME/memory/$1/overview.md"; }
wt() { git -C "$M" worktree add -q -b "$2" "$1" main; git -C "$1" commit -q --allow-empty -m "$2"; }
rev() { git -C "$M" rev-parse "$1"; }
ct() { (cd "${3:-$M}" && GH_TSV="$2" n1_clean_ticket "$1" clean) | paste -sd, -; }
cl() { grep '^- \*\*Cleanup:\*\*' "$N1_HOME/memory/$1/overview.md"; }

# K1: MERGED PR, run from the main checkout: worktree removed, branch deleted, overview recorded.
wt "$T/k1" b1; git -C "$M" merge -q --no-ff -m m1 b1; ov K-1
eq "K1: merged -> removed" "worktree:removed,branch:deleted" "$(ct K-1 "$(printf 'MERGED\tb1\t%s\tmain' "$(rev b1)")")"
eq "K1: dir gone" no "$(yn test -d "$T/k1")"
eq "K1: overview line" "- **Cleanup:** worktree:removed, branch:deleted ($T/k1)" "$(cl K-1)"
eq "K1: one Finish section" 1 "$(grep -c '^## Finish' "$N1_HOME/memory/K-1/overview.md")"
eq "K1: pr_url still readable" yes "$(yn grep -q "^pr_url: $URL" "$N1_HOME/memory/K-1/overview.md")"
eq "K1: no step event when unbound" no "$(yn test -d "$N1_HOME/memory/K-1/telemetry")"
# K2: idempotent re-run.
eq "K2: re-run no-ops" "worktree:none,branch:none" "$(ct K-1 "$(printf 'MERGED\tb1\t%s\tmain' "$(rev main)")")"
eq "K2: real record survives no-op" "- **Cleanup:** worktree:removed, branch:deleted ($T/k1)" "$(cl K-1)"
eq "K2: single Cleanup line" 1 "$(grep -c '^- \*\*Cleanup:\*\*' "$N1_HOME/memory/K-1/overview.md")"
# K3/K4: OPEN or CLOSED PR: nothing touched, no overview line.
wt "$T/k3" b3; echo x > "$T/k3/d"; ov K-3
eq "K3: open PR skipped" "cleanup:skipped (pr-not-merged)" "$(ct K-3 "$(printf 'OPEN\tb3\t%s\tmain' "$(rev b3)")")"
eq "K3: dirty dir kept" yes "$(yn test -f "$T/k3/d")"
eq "K3: branch kept" yes "$(yn git -C "$M" show-ref -q --verify refs/heads/b3)"
eq "K3: no overview line" "" "$(cl K-3)"
eq "K4: closed PR skipped" "cleanup:skipped (pr-not-merged)" "$(ct K-3 "$(printf 'CLOSED\tb3\t%s\tmain' "$(rev b3)")")"
# K5: no pr_url -> skipped without calling gh.
ov K-5 ""; : > "$GH_CALLS"
eq "K5: no pr skipped" "cleanup:skipped (no-pr)" "$(ct K-5 x)"
eq "K5: gh not called" "" "$(cat "$GH_CALLS")"
# K6: run from inside the target worktree (plain git).
wt "$T/k6" b6; git -C "$M" merge -q --no-ff -m m6 b6; ov K-6
eq "K6: from inside target" "worktree:removed,branch:deleted" "$(ct K-6 "$(printf 'MERGED\tb6\t%s\tmain' "$(rev b6)")" "$T/k6")"
# K7: another ticket's worktree is never touched; the main checkout is never selected.
wt "$T/k7" b7; git -C "$M" branch -q b8; ov K-8
eq "K7: other worktree untouched" "worktree:none,branch:deleted" "$(ct K-8 "$(printf 'MERGED\tb8\t%s\tmain' "$(rev b8)")" "$T/k7")"
eq "K7: other dir kept" yes "$(yn test -d "$T/k7")"
ov K-9
eq "K9: head == default branch -> main untouched" "worktree:none,branch:none" "$(ct K-9 "$(printf 'MERGED\tmain\t%s\tmain' "$(rev main)")")"
eq "K9: main checkout intact" yes "$(yn test -d "$M/.git")"
# K10: invalid id.
eq "K10: invalid id" "cleanup:skipped (invalid-id)" "$(n1_clean_ticket '../x' clean)"
# K11: detached workspace_path worktree is reported, never removed.
wt "$T/k11" b11; git -C "$M" merge -q --no-ff -m m11 b11; git -C "$T/k11" checkout -q --detach; ov K-11
sed -i "2i workspace_path: $T/k11" "$N1_HOME/memory/K-11/overview.md"
eq "K11: detached diagnostic" "worktree:kept (workspace_path $T/k11 holds detached),branch:deleted" "$(ct K-11 "$(printf 'MERGED\tb11\t%s\tmain' "$(rev b11)")")"
eq "K11: dir kept" yes "$(yn test -d "$T/k11")"
# K12: queue env -> ticket_cleanup event with outcome and reason.
mkdir -p "$T/q/Q-1"; wt "$T/k12" b12; git -C "$M" merge -q --no-ff -m m12 b12; echo x > "$T/k12/d"; ov K-12
(export N1_QUEUE_DIR="$T/q/Q-1" N1_QUEUE_RUN_ID=r1; ct K-12 "$(printf 'MERGED\tb12\t%s\tmain' "$(rev b12)")" >/dev/null)
eq "K12: queue event" "Q-1|r1|skipped|worktree:kept (dirty), branch:kept (checked out in $T/k12); $T/k12" \
    "$(jq -r 'select(.event == "ticket_cleanup" and .ticket == "K-12") | "\(.queue)|\(.run_id)|\(.outcome)|\(.reason)"' "$T/q/Q-1/events.jsonl")"
eq "K12: no queue event without queue env" no "$(yn grep -q '"ticket":"K-1"' "$T/q/Q-1/events.jsonl")"
# K13: bound run -> cleanup step event 18 with the metadata keys.
wt "$T/k13" b13; git -C "$M" merge -q --no-ff -m m13 b13; ov K-13
(export N1_RUN_ID=run-13; ct K-13 "$(printf 'MERGED\tb13\t%s\tmain' "$(rev b13)")" >/dev/null)
eq "K13: step event" "cleanup|18|success|clean|false|[\"branch\",\"cwd\",\"orca\",\"path\",\"reason\",\"trigger\",\"worktree\"]" \
    "$(jq -rc '"\(.step)|\(.step_number)|\(.outcome)|\(.metadata.trigger)|\(.metadata.orca)|\(.metadata | keys)"' "$N1_HOME/memory/K-13/telemetry/raw/steps/run-13.jsonl")"
# K13b: a removed worktree with a kept branch is outcome skipped (listed by n1_queue_cleanup_left).
ov K-13b
(export N1_RUN_ID=run-13b; _n1_clean_record K-13b clean "worktree:removed, branch:kept (not merged)" "$T/k13b" git)
eq "K13b: branch kept -> skipped" skipped "$(jq -r .outcome "$N1_HOME/memory/K-13b/telemetry/raw/steps/run-13b.jsonl")"
# K14: finish trigger rewrites finish-report.md's pending Cleanup line, no gh call.
wt "$T/k14" b14; git -C "$M" merge -q --no-ff -m m14 b14; ov K-14
printf 'Finish complete: K-14\nCleanup: <pending>\n' > "$N1_HOME/memory/K-14/finish-report.md"; : > "$GH_CALLS"
(cd "$M" && n1_clean_ticket K-14 finish b14 "$(rev b14)" main >/dev/null)
eq "K14: report line rewritten" "Cleanup: worktree:removed, branch:deleted" "$(grep '^Cleanup:' "$N1_HOME/memory/K-14/finish-report.md")"
eq "K14: finish trigger never calls gh" "" "$(cat "$GH_CALLS")"
# K15: finish trigger with an empty id still cleans (n1-finish standalone without memory).
eq "K15: empty id finish" "worktree:none,branch:none" "$( (cd "$M" && n1_clean_ticket "" finish "" "" main) | paste -sd, -)"

# n1-clean wiring (N1-339 D5).
S="$R/skills/n1-clean/SKILL.md"
# W1: non-finish triggers never force an N1-managed tree (dirty / unmerged stay kept); finish still forces.
WR="$(n1_worktree_root)"; mkdir -p "$M/$WR"
wt "$M/$WR/w1" bw1; git -C "$M" merge -q --no-ff -m mw1 bw1; echo x > "$M/$WR/w1/d"; ov K-70
eq "W1: dirty merged N1 tree kept" "worktree:kept (dirty),branch:kept (checked out in $M/$WR/w1)" "$(ct K-70 "$(printf 'MERGED\tbw1\t%s\tmain' "$(rev bw1)")")"
eq "W1: dir stays" yes "$(yn test -d "$M/$WR/w1")"
wt "$M/$WR/w1b" bw1b; ov K-71
eq "W1b: unmerged N1 tree kept" "worktree:kept (unmerged),branch:kept (checked out in $M/$WR/w1b)" "$(ct K-71 "$(printf 'MERGED\tbw1b\t%s\tmain' "$(rev main)")")"
eq "W1b: dir stays" yes "$(yn test -d "$M/$WR/w1b")"
wt "$M/$WR/w1c" bw1c; git -C "$M" merge -q --no-ff -m mw1c bw1c; echo x > "$M/$WR/w1c/d"
eq "W1c: finish trigger still forces" "worktree:removed,branch:deleted" "$( (cd "$M" && n1_clean_ticket "" finish bw1c "$(rev bw1c)" main) | paste -sd, -)"
# CR-2: a run id bound only for the call (as 06-cleanup.md does) carries the cleanup event from the finish trigger.
wt "$M/$WR/w2" bw2; git -C "$M" merge -q --no-ff -m mw2 bw2; echo x > "$M/$WR/w2/d"; ov K-72
(cd "$M" && N1_RUN_ID=run-w2 n1_clean_ticket K-72 finish bw2 "$(rev bw2)" main >/dev/null)
eq "W2e: finish emits cleanup event" "cleanup|success" "$(jq -r '"\(.step)|\(.outcome)"' "$N1_HOME/memory/K-72/telemetry/raw/steps/run-w2.jsonl")"
eq "W2e: skill binds run id" yes "$(yn grep -qF 'N1_RUN_ID="${N1_RUN_ID:-$RUN}" n1_clean_ticket' "$R/skills/n1-finish/steps/06-cleanup.md")"
eq "W2: ticket mode calls n1_clean_ticket" yes "$(yn grep -qF 'n1_clean_ticket "$ID"' "$S")"
eq "W3: --ticket mode documented" yes "$(yn grep -qF -- '--ticket <ID>' "$S")"
eq "W4: discovery not limited to the N1 worktree root" 0 "$(grep -c 'n1_worktree_root' "$S")"
eq "W5: general mode removes through n1_clean_ticket" yes "$(yn grep -qF 'n1_clean_ticket "<ID>" general' "$S")"
eq "W6: auto mode never removes Abandoned" yes "$(yn grep -qF 'never removes Abandoned' "$S")"
eq "W7: Orca worktrees tagged" yes "$(yn grep -qF 'n1_orca_owns' "$S")"
eq "W8: Completed requires a merged PR" yes "$(yn grep -qF 'MERGED' "$S")"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
