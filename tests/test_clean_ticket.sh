#!/usr/bin/env bash
# tests/test_clean_ticket.sh — N1-339: n1_clean_ticket (ticket-keyed cleanup) and n1-clean wiring.
# Run: bash tests/test_clean_ticket.sh
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; R="$SCRIPT_DIR/.."
source "$R/lib/config.sh"
source "$R/lib/telemetry.sh"
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else e=$(printf %s "$2" | tr '\n()' '  []'); a=$(printf %s "$3" | tr '\n()' '  []'); echo "FAIL: $1 (expected='$e' actual='$a')"; FAIL=$((FAIL + 1)); fi; }
yn() { "$@" && echo yes || echo no; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset ORCA_CLI_COMMAND N1_RUN_ID N1_QUEUE_DIR N1_QUEUE_RUN_ID
mkdir -p "$T/bin" "$N1_HOME/memory"
# gh stub: logs argv; for "--state open" lists prints the head of each "head base" line in $GH_OPEN, plus the base
# when baseRefName was requested (as the real -q '.[] | .headRefName, .baseRefName' does); else $GH_TSV (state, headRefName, headRefOid,
# baseRefName; or merged-PR rows for n1_clean_scan). Never left empty in a case that reaches gh pr view (retry backoff).
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case " $* " in *" --state open "*) case "$*" in *baseRefName*) printf '%s\n' "${GH_OPEN:-}" | tr ' ' '\n' ;; *) printf '%s\n' "${GH_OPEN:-}" | cut -d' ' -f1 ;; esac ;; *) printf '%s\n' "${GH_TSV:-}" ;; esac
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
# K2b: a verified no-op replaces an earlier kept/failed record.
ov K-29; printf '## Finish\n- **Cleanup:** worktree:kept (dirty), branch:kept (not merged)\n' >> "$N1_HOME/memory/K-29/overview.md"
ct K-29 "$(printf 'MERGED\tb1\t%s\tmain' "$(rev main)")" >/dev/null
eq "K2b: no-op resolves prior kept" "- **Cleanup:** worktree:none, branch:none" "$(cl K-29)"
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
# S1-S6 (N1-577): a spike ticket is never pending merge work; a kept spike worktree is never the ticket's workspace.
mkdir -p "$N1_HOME/memory/S-1"; printf -- '---\nstep: done\ntype: investigation\nvariant: spike\n---\n# S-1\n' > "$N1_HOME/memory/S-1/overview.md"; : > "$GH_CALLS"
eq "S1: spike ticket without pr_url skipped" "cleanup:skipped (no-pr)" "$(ct S-1 x)"
eq "S1: gh not called for a spike ticket" "" "$(cat "$GH_CALLS")"
git -C "$M" worktree add -q -b spike/S-2 "$T/spike-S-2" main; git -C "$T/spike-S-2" commit -q --allow-empty -m s2
eq "S2: kept spike worktree not found for its ticket" "" "$(cd "$M" && n1_find_workspace S-2)"
eq "S3: kept spike worktree not owned by its ticket" "1" "$(cd "$T/spike-S-2" && { n1_worktree_owned S-2; echo $?; })"
wt "$T/S-4" b-s4
eq "S4: normal <ID> worktree still found by folder" "$T/S-4" "$(cd "$M" && n1_find_workspace S-4)"
wt "$T/x5" feature/S-5
eq "S5: normal worktree still found by branch" "$T/x5" "$(cd "$M" && n1_find_workspace S-5)"
eq "S6: n1-finish stops on spike branches" "1" "$(grep -c 'starts with `spike/`' "$R/skills/n1-finish/steps/01-resolve-target.md")"
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
# K11 (N1-583): a detached workspace_path worktree is removed when its HEAD is within the merged PR; kept otherwise.
wt "$T/k11" b11; git -C "$M" merge -q --no-ff -m m11 b11; git -C "$T/k11" checkout -q --detach; ov K-11
sed -i "2i workspace_path: $T/k11" "$N1_HOME/memory/K-11/overview.md"
eq "K11: detached workspace_path tree removed" "worktree:removed,branch:deleted" "$(ct K-11 "$(printf 'MERGED\tb11\t%s\tmain' "$(rev b11)")")"
eq "K11: dir gone" no "$(yn test -d "$T/k11")"
eq "K11: path recorded" "- **Cleanup:** worktree:removed, branch:deleted ($T/k11)" "$(cl K-11)"
wt "$T/k11b" b11b; git -C "$M" merge -q --no-ff -m m11b b11b; git -C "$T/k11b" checkout -q --detach
git -C "$T/k11b" commit -q --allow-empty -m extra; ov K-111
sed -i "2i workspace_path: $T/k11b" "$N1_HOME/memory/K-111/overview.md"
eq "K11b: commit outside the merged PR -> kept" "worktree:kept (unmerged),branch:deleted" "$(ct K-111 "$(printf 'MERGED\tb11b\t%s\tmain' "$(rev b11b)")")"
eq "K11b: dir kept" yes "$(yn test -d "$T/k11b")"
# K16 (AC4): PR head maphskiy/jiaolong, local tree on maphskiy/otter -> resolved through workspace_path.
wt "$T/k16" maphskiy/otter; ov K-16; sed -i "2i workspace_path: $T/k16" "$N1_HOME/memory/K-16/overview.md"
eq "K16: renamed-branch tree resolved through workspace_path" "worktree:removed,branch:none" "$(ct K-16 "$(printf 'MERGED\tmaphskiy/jiaolong\t%s\tmain' "$(rev maphskiy/otter)")")"
eq "K16: dir gone" no "$(yn test -d "$T/k16")"
eq "K16: local branch untouched" yes "$(yn git -C "$M" show-ref -q --verify refs/heads/maphskiy/otter)"
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
G="$R/skills/n1-clean/general.md"  # general-mode steps
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
eq "W4: discovery not limited to the N1 worktree root" 0 "$(cat "$S" "$G" | grep -c 'n1_worktree_root')"
eq "W5: general mode removes through n1_clean_ticket" yes "$(yn grep -qF 'n1_clean_ticket "<ID>" general' "$G")"
eq "W6: auto mode never removes Abandoned" yes "$(yn grep -qF 'never removes Abandoned' "$G")"
eq "W7: Orca worktrees tagged" yes "$(yn grep -qF 'n1_orca_owns' "$G")"
eq "W8: Completed requires a merged PR" yes "$(yn grep -qF 'MERGED' "$G")"
# W10-W18 (N1-583): general mode scans, asks before removing (interactive), keeps the autonomy gate when unattended.
eq "W10: general mode runs the leftover scan" yes "$(yn grep -qF 'n1_clean_scan' "$G")"
eq "W11: no-PR trees removed through merged-nopr" yes "$(yn grep -qF 'n1_clean_ticket "<ID>" merged-nopr' "$G")"
eq "W12: run-mode detection" yes "$(yn grep -qF 'echo mode:unattended || echo mode:interactive' "$G")"
eq "W13: both prompts carry the no-recommendation sentence" 2 "$(grep -cF 'No recommendation. The options are equivalent given the available evidence; select based on team preference.' "$G")"
eq "W14: no option marked Recommended" 0 "$(grep -cF '(Recommended)' "$G")"
eq "W15: skill never removes worktrees with plain git" 0 "$(cat "$S" "$G" | grep -c 'git worktree remove')"
eq "W16: unattended runs never remove leftovers" yes "$(yn grep -qF 'unattended runs never remove Leftovers or remote branches' "$G")"
eq "W17: remote branches deleted one at a time by full ref" yes "$(yn grep -qF 'git push origin --delete "refs/heads/<branch>"' "$G")"
eq "W18: nothing removed before the answer" yes "$(yn grep -qF 'nothing has been removed yet' "$G")"

# W9 (N1-347): Step 1 discovery snippet. Main checkout excluded, branch name without refs/heads/,
# detached and missing trees reported. Orca ownership stubbed off.
STEP1=$(awk '/^## Step 1:/{s=1} s&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$G" | sed '/preamble\.sh/d')
wt "$T/s1" bs1
git -C "$M" worktree add -q --detach "$T/s2" main
wt "$T/s3" bs3; rm -rf "$T/s3"
D1=$(cd "$M" && n1_orca_owns() { return 1; }; eval "$STEP1")
eq "W9: branch tree listed" yes "$(yn grep -qxF "$(printf '%s\tbs1\tplain\tpresent' "$T/s1")" <<<"$D1")"
eq "W9: detached tree listed" yes "$(yn grep -qxF "$(printf '%s\tdetached\tplain\tpresent' "$T/s2")" <<<"$D1")"
eq "W9: missing tree listed" yes "$(yn grep -qxF "$(printf '%s\tbs3\tplain\tmissing' "$T/s3")" <<<"$D1")"
eq "W9: main checkout excluded" 0 "$(grep -c "^$M	" <<<"$D1")"
eq "W9: four fields per line" 0 "$(awk -F'\t' 'NF!=4' <<<"$D1" | wc -l | tr -d ' ')"

# N1-277: a Finish written by n1_clean_ticket also clears the awaiting-merge marker (both shapes); pr_url stays readable.
mkdir -p "$N1_HOME/memory/K-77"; O77="$N1_HOME/memory/K-77/overview.md"
printf -- '---\nstep: pr\nawaiting: merge\n---\n# K-77\n## Pending\nawaiting: merge\npr: 7\npr_url: %s\nbranch: b77\nlast_checked: 2026-01-01T00:00:00Z\ncreated: 2026-01-01T00:00:00Z\n' "$URL" > "$O77"
ct K-77 "$(printf 'MERGED\tb77\t%s\tmain' "$(rev main)")" >/dev/null
eq "P1: Cleanup line recorded" yes "$(yn grep -q '^- \*\*Cleanup:\*\*' "$O77")"
eq "P1: no awaiting line" no "$(yn grep -q '^awaiting:' "$O77")"
eq "P1: no ## Pending heading" no "$(yn grep -qx '## Pending' "$O77")"
eq "P1: pr_url kept" yes "$(yn grep -qx "pr_url: $URL" "$O77")"
eq "P1: n1-clean URL reader still finds pr_url" "$URL" "$(awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$O77")"

# N0-N6 (N1-583): merged-nopr trigger (n1-clean general mode after confirmation). A no-PR tree is removed only when
# clean and its HEAD is an ancestor of origin/<default>; local <default> may lag behind origin.
git init -q --bare "$T/origin.git"; git -C "$M" remote add origin "$T/origin.git"; git -C "$M" push -q origin main
nov() { mkdir -p "$N1_HOME/memory/$1"; printf -- '---\nstep: %s\n---\n# %s\n' "${2:-done}" "$1" > "$N1_HOME/memory/$1/overview.md"; }
nc() { (cd "${2:-$M}" && n1_clean_ticket "$1" merged-nopr) | paste -sd, -; }
wt "$T/N-1" n1b; git -C "$M" push -q origin n1b:main; nov N-1
O=$(git -C "$M" rev-parse origin/main)
git -C "$M" worktree add -q -b n2b "$T/N-2" "$O"; echo x > "$T/N-2/d"; nov N-2
git -C "$M" worktree add -q -b n3b "$T/N-3" "$O"; git -C "$T/N-3" commit -q --allow-empty -m n3; nov N-3
git -C "$M" worktree add -q -b spike/N-4 "$T/spike-N-4" "$O"; nov N-4
sed -i "2i workspace_path: $T/spike-N-4" "$N1_HOME/memory/N-4/overview.md"
: > "$GH_CALLS"
eq "N0: general trigger keeps the no-pr skip" "cleanup:skipped (no-pr)" "$( (cd "$M" && n1_clean_ticket N-1 general) | paste -sd, -)"
eq "N0: gh not called" "" "$(cat "$GH_CALLS")"
eq "N0: local main is behind origin" no "$(yn git -C "$M" merge-base --is-ancestor n1b main)"
eq "N1: clean tree merged into origin/main removed" "worktree:removed,branch:deleted" "$(nc N-1)"
eq "N1: dir gone" no "$(yn test -d "$T/N-1")"
eq "N1: recorded in ## Finish" "- **Cleanup:** worktree:removed, branch:deleted ($T/N-1)" "$(cl N-1)"
eq "N2: dirty tree kept" "worktree:kept (dirty),branch:kept (checked out in $T/N-2)" "$(nc N-2)"
eq "N3: not an ancestor of origin/main -> kept" "worktree:kept (unmerged),branch:kept (checked out in $T/N-3)" "$(nc N-3)"
eq "N4: spike tree refused" "cleanup:skipped (spike)" "$(nc N-4)"
eq "N4: spike dir kept" yes "$(yn test -d "$T/spike-N-4")"
eq "N5: no workspace -> skipped" "cleanup:skipped (no-workspace)" "$(nc N-5)"
nov N-7 implement; git -C "$M" worktree add -q -b n7b "$T/N-7" "$O"; sed -i "2i workspace_path: $T/N-7" "$N1_HOME/memory/N-7/overview.md"
eq "N7: ticket not at step done is skipped" "cleanup:skipped (not-done)" "$(nc N-7)"
eq "N7: tree kept" yes "$(yn test -d "$T/N-7")"
eq "N6: invalid id" "cleanup:skipped (invalid-id)" "$(n1_clean_ticket '../x' merged-nopr)"

# L1-L8 (N1-583): n1_clean_scan lists leftovers and removes nothing.
O=$(git -C "$M" rev-parse origin/main)
git -C "$M" worktree add -q -b l1b "$T/L-1" "$O"; nov L-1                # clean, on origin/main, step done
git -C "$M" worktree add -q -b l10b "$T/L-10" "$O"                      # fresh tree, no overview: not provably finished (CR-3/SEC-1)
mkdir -p "$T/wts2/empty-c"; git -C "$M" worktree add -q -b l11b "$T/wts2/L-11" "$O"   # a worktree container
git -C "$M" worktree add -q -b l2b "$T/L-2" "$O"; nov L-2 implement     # in progress
git -C "$M" worktree add -q -b l3b "$T/L-3" "$O"; ov L-3                # has a PR: Step 2 classifies it
mkdir -p "$T/empty-583" "$M/$WR/empty-wr"
mkdir -p "$N1_HOME/memory/L-7" "$N1_HOME/memory/L-8" "$N1_HOME/memory/L-9"
printf -- '---\nstep: done\nawaiting: merge\n---\n# L-7\n## Finish\n- **Cleanup:** worktree:none, branch:none\n' > "$N1_HOME/memory/L-7/overview.md"
printf -- '---\nstep: pr\nawaiting: merge\n---\n# L-8\n## Pending\nawaiting: merge\n' > "$N1_HOME/memory/L-8/overview.md"
printf -- '---\nstep: done\n---\n# L-9\n## Pending\r\nawaiting: merge\r\n## Finish\r\n' > "$N1_HOME/memory/L-9/overview.md"
git -C "$M" branch -q rb-1 main; git -C "$M" branch -q rb-3 main; wt "$T/rb4" rb-4
git -C "$M" push -q origin rb-1 rb-3 rb-4 "$O:refs/heads/rb-2" spike/S-2 main:refs/heads/rb-5 main:refs/heads/develop main:refs/heads/nokey
MO=$(rev main)
RB=$(printf 'rb-1\t%s\tU1\nrb-2\t%s\tU2\nrb-3\t%s\tU3\nrb-4\t%s\tU4\nspike/S-2\t%s\tU5\nmain\t%s\tU6\ngone\t%s\tU7\nrb-5\t%s\tU8\ndevelop\t%s\tU9\nnokey\t%s\tU10' \
    "$MO" "$MO" "$MO" "$(rev rb-4)" "$(rev spike/S-2)" "$O" "$MO" "$MO" "$MO" "$MO")
SC=$(cd "$M" && GH_TSV="$RB" GH_OPEN=$'rb-3 rb-5' n1_clean_scan)
row() { printf '%s\t%s\t%s\t%s' "$@"; }
hr() { yn grep -qxF "$(row "$@")" <<<"$SC"; }
eq "L1: clean no-PR tree on origin/main listed" yes "$(hr nopr-worktree L-1 "$T/L-1" l1b)"
eq "L2: in-progress tree not listed" 0 "$(grep -cF "$T/L-2" <<<"$SC")"
eq "L3: tree with a PR not listed" 0 "$(grep -cF "$T/L-3" <<<"$SC")"
eq "L4: dirty, unmerged and spike trees not listed" 0 "$(grep -cF -e "$T/N-2	" -e "$T/N-3	" -e "$T/spike-N-4	" <<<"$SC")"
eq "L1b: fresh tree without overview not listed" 0 "$(grep -cF "$T/L-10" <<<"$SC")"
eq "L5: empty dir in a worktree container listed" yes "$(hr empty-dir - "$T/wts2/empty-c" -)"
eq "L5: empty dir beside unrelated entries not listed (CR-1)" 0 "$(grep -cF "$T/empty-583" <<<"$SC")"
eq "L5: empty dir under the N1 root listed" yes "$(hr empty-dir - "$M/$WR/empty-wr" -)"
eq "L5: non-empty dir not listed" 0 "$(grep -cF "$T/bin" <<<"$SC")"
eq "L6: stale marker listed" yes "$(hr stale-marker L-7 "$N1_HOME/memory/L-7/overview.md" -)"
eq "L6: CRLF stale marker listed" yes "$(hr stale-marker L-9 "$N1_HOME/memory/L-9/overview.md" -)"
eq "L6: still-pending ticket not listed" 0 "$(grep -c '^stale-marker	L-8	' <<<"$SC")"
eq "L7: only the merged branch still at its PR head listed" "$(row remote-branch - rb-1 U1)" "$(grep '^remote-branch' <<<"$SC")"
eq "L7b: base of an open PR excluded (CR-2)" 0 "$(grep -cF rb-5 <<<"$SC")"
eq "L7b: develop and non-ticket branches excluded" 0 "$(grep -cE 'develop|nokey' <<<"$SC")"
eq "L8: scan removed nothing" "yes yes yes 1" "$(yn test -d "$T/L-1") $(yn test -d "$T/empty-583") $(yn grep -q '^awaiting: merge' "$N1_HOME/memory/L-7/overview.md") $(git -C "$M" ls-remote origin refs/heads/rb-1 | wc -l | tr -d ' ')"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
