#!/usr/bin/env bash
# tests/test_queue_finish.sh — N1-532: n1_queue_final_landed / n1_queue_finish_child (n1-finish on a queue final PR).
# Run: bash tests/test_queue_finish.sh
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; mkdir -p "$N1_HOME/queue/q1" "$T/other" "$T/bin" "$T/gh"
source "$R/lib/config.sh"; source "$R/lib/frontmatter.sh"; source "$R/lib/queue.sh"
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 (expected='$2' actual='$3')"; FAIL=$((FAIL + 1)); fi; }
# fake gh: "gh repo view ..." prints $T/gh/nwo (no file -> exit 1); "gh pr view ... -- <url>" prints $T/gh/state.<num>
# (with baseRefName: "<state>\t<base>\toid", base from $T/gh/base.<num>, default queue/q1-x); no state file -> exit 1
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = repo ]; then [ -f "$T/gh/nwo" ] || exit 1; cat "$T/gh/nwo"; exit 0; fi
u="\${@: -1}"; n="\${u##*/}"; f="$T/gh/state.\$n"; [ -f "\$f" ] || exit 1
if [[ "\$*" == *headRefName* ]]; then h=queue/q1-x; [ -f "$T/gh/head.\$n" ] && h=\$(cat "$T/gh/head.\$n"); echo "\$h"; exit 0; fi
if [[ "\$*" == *baseRefName* ]]; then b=queue/q1-x; [ -f "$T/gh/base.\$n" ] && b=\$(cat "$T/gh/base.\$n"); printf '%s\t%s\toid\n' "\$(cat "\$f")" "\$b"; else cat "\$f"; fi
EOF
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
U=https://github.com/o/r/pull; Q="$N1_HOME/queue/q1/queue.md"
cat > "$Q" <<EOF
---
run_id: R1
integration: queue
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|---|---|---|---|---|---|---|
| 1 | T-1 | a | /r | $N1_HOME | sonnet | pr | merged; done at final PR |
| 2 | T-2 | b | /r | $N1_HOME | sonnet | failed | boom |
| 3 | T-3 | c | /x | $N1_HOME | sonnet | pr | merged; done at final PR |
| 4 | T-4 | d | /r | $T/other | sonnet | pr | merged; done at final PR |
| 5 | ../e | e | /r | $N1_HOME | sonnet | pr | merged |
## Story Branches
| Repo | Branch |
|------|--------|
| /r | queue/q1-x |
## Final PRs
| Repo | PR | Draft | Mergeable | Note |
|---|---|---|---|---|
| /r | $U/9 | ready | MERGEABLE | - |
## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|---|---|---|---|---|---|
| T-1 | x | 0 | merged | $U/1 | s1 |
| T-2 | x | 1 | failed | | s2 |
| T-3 | x | 0 | merged | $U/3 | s3 |
| T-4 | x | 0 | merged | $U/4 | s4 |
| ../e | x | 0 | merged | $U/5 | s5 |
EOF
echo "{\"event\":\"final_pr_opened\",\"run_id\":\"R1\",\"pr\":\"$U/9\"}" > "$N1_HOME/queue/q1/events.jsonl"
for n in 1 3 4 5; do echo "{\"event\":\"ticket_finished\",\"run_id\":\"R1\",\"ticket\":\"$(case $n in 1) echo T-1;; 3) echo T-3;; 4) echo T-4;; 5) echo ../e;; esac)\",\"outcome\":\"merged\",\"pr\":\"$U/$n\"}" >> "$N1_HOME/queue/q1/events.jsonl"; done
for n in 1 3 4 5 9; do echo MERGED > "$T/gh/state.$n"; done

# L1: landed / unlanded split for the final PR's repo only (T-3 is another repo's final PR)
out=$(n1_queue_final_landed "$U/9"); rc=$?
eq "L1: rc 0" 0 "$rc"
eq "L1: lines" "$(printf 'queue %s\nlanded\tT-1\t%s/1\nunlanded\tT-2\tfailed\nunlanded\tT-4\tother N1 Home\nunlanded\t-\tinvalid ticket id' "$Q" "$U")" "$out"
# L2: a child PR that is not MERGED is not landed
echo OPEN > "$T/gh/state.1"
eq "L2: open child PR" "$(printf 'unlanded\tT-1\tchild PR not merged')" "$(n1_queue_final_landed "$U/9" | grep T-1)"
echo MERGED > "$T/gh/state.1"
# L2b (SEC-1): a MERGED child PR whose base is not the queue branch is not landed
echo main > "$T/gh/base.1"
eq "L2b: wrong base" "$(printf 'unlanded\tT-1\tchild PR not in queue branch')" "$(n1_queue_final_landed "$U/9" | grep T-1)"
rm "$T/gh/base.1"
# L2c (SEC-1): no runner-written ticket_finished event for the row -> not landed
cp "$N1_HOME/queue/q1/events.jsonl" "$T/ev0"; grep -v '"ticket":"T-1"' "$T/ev0" > "$N1_HOME/queue/q1/events.jsonl"
eq "L2c: no event" "$(printf 'unlanded\tT-1\tchild PR not in queue branch')" "$(n1_queue_final_landed "$U/9" | grep T-1)"
mv "$T/ev0" "$N1_HOME/queue/q1/events.jsonl"
# L3: unknown final PR -> queue:none, rc 1
out=$(n1_queue_final_landed "$U/99"); rc=$?
eq "L3: none" "queue:none|1" "$out|$rc"
# L4: a Final PRs row without a runner-written final_pr_opened event is not trusted
mv "$N1_HOME/queue/q1/events.jsonl" "$T/ev"; out=$(n1_queue_final_landed "$U/9"); rc=$?
eq "L4: unattested final PR" "queue:none|1" "$out|$rc"; mv "$T/ev" "$N1_HOME/queue/q1/events.jsonl"
# L5: two queues recording the same final PR fail closed
cp -r "$N1_HOME/queue/q1" "$N1_HOME/queue/q2"; out=$(n1_queue_final_landed "$U/9"); rc=$?
eq "L5: ambiguous" "queue:ambiguous|1" "$out|$rc"; rm -rf "$N1_HOME/queue/q2"
# L6: a story-mode queue (no integration: queue) is never matched
sed -i 's/^integration: queue$/mode: story/' "$Q"; out=$(n1_queue_final_landed "$U/9"); rc=$?
eq "L6: story queue ignored" "queue:none|1" "$out|$rc"; sed -i 's/^mode: story$/integration: queue/' "$Q"

# H (N1-616): a child merged into the queue branch by hand after the runner exited (row pr, Runs Outcome pr, no event)
# is recorded by the reconcile inside n1_queue_final_landed and lands. SEC-1: wrong base (H-2), OPEN (H-3), another
# repo's PR (H-4) and a live runner stay unlanded and are not rewritten.
mkdir -p "$N1_HOME/queue/q3" "$T/repo"; Q3="$N1_HOME/queue/q3/queue.md"; E3="$N1_HOME/queue/q3/events.jsonl"
echo o/r > "$T/gh/nwo"; echo MERGED > "$T/gh/state.30"; echo queue/q3-x > "$T/gh/head.30"   # final PR head (SEC-1 binding)
cat > "$Q3" <<EOF
---
queue_id: q3
run_id: R3
integration: queue
---
## Plan
| # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
|---|---|---|---|---|---|---|---|
| 1 | H-1 | a | $T/repo | $N1_HOME | sonnet | pr | finish:no-pin (review-failed) |
| 2 | H-2 | b | $T/repo | $N1_HOME | sonnet | pr | finish:no-pin (review-failed) |
| 3 | H-3 | c | $T/repo | $N1_HOME | sonnet | pr | finish:no-pin (review-failed) |
| 4 | H-4 | d | $T/repo | $N1_HOME | sonnet | pr | finish:no-pin (review-failed) |
## Story Branches
| Repo | Branch |
|------|--------|
| $T/repo | queue/q3-x |
## Final PRs
| Repo | PR | Draft | Mergeable | Note |
|---|---|---|---|---|
| $T/repo | $U/30 | ready | MERGEABLE | - |
## Runs
| Ticket | Started | Exit | Outcome | PR | Session |
|---|---|---|---|---|---|
| H-1 | x | 0 | pr | $U/31 | s1 |
| H-2 | x | 0 | pr | $U/32 | s2 |
| H-3 | x | 0 | pr | $U/33 | s3 |
| H-4 | x | 0 | pr | https://github.com/o/other/pull/34 | s4 |
EOF
echo "{\"event\":\"final_pr_opened\",\"run_id\":\"R3\",\"pr\":\"$U/30\"}" > "$E3"
for n in 31 32 34; do echo MERGED > "$T/gh/state.$n"; done; echo OPEN > "$T/gh/state.33"
for n in 31 33 34; do echo queue/q3-x > "$T/gh/base.$n"; done; echo main > "$T/gh/base.32"
# H0: a live runner records merges itself, so the reconcile is skipped and nothing lands
bash -c 'sleep 30; :' scripts/n1-queue-run.sh "$Q3" & P=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qa n1-queue-run "/proc/$P/cmdline" 2>/dev/null && break; sleep 0.1; done
n1_write_frontmatter "$Q3" pid "$P"
eq "H0: live runner, no reconcile" "$(printf 'unlanded\tH-1\tpr')" "$(n1_queue_final_landed "$U/30" | grep H-1)"
eq "H0: no event written" 0 "$(jq -c 'select(.event == "ticket_finished")' "$E3" | wc -l | tr -d ' ')"
kill "$P" 2>/dev/null; wait "$P" 2>/dev/null; sed -i '/^pid: /d' "$Q3"
# H1: runner gone: the hand-merged child lands; the others stay unlanded
out=$(n1_queue_final_landed "$U/30"); rc=$?
eq "H1: rc 0" 0 "$rc"
eq "H1: lines" "$(printf 'queue %s\nlanded\tH-1\t%s/31\nunlanded\tH-2\tpr\nunlanded\tH-3\tpr\nunlanded\tH-4\tpr' "$Q3" "$U")" "$out"
eq "H1: Outcome merged for H-1 only" "merged pr pr pr" \
    "$(for t in H-1 H-2 H-3 H-4; do _n1_queue_run_outcome "$Q3" "$t"; done | paste -sd' ' -)"
eq "H1: one runner-format event, H-1 only" "H-1|R3|$U/31" \
    "$(jq -r 'select(.event == "ticket_finished" and .outcome == "merged") | "\(.ticket)|\(.run_id)|\(.pr)"' "$E3")"
# H2: re-running is idempotent
eq "H2: same lines on rerun" "$out" "$(n1_queue_final_landed "$U/30")"
eq "H2: still one event" 1 "$(jq -c 'select(.event == "ticket_finished")' "$E3" | wc -l | tr -d ' ')"
# H3: the runner Note helper sees the same landed set
eq "H3: finish state counts the hand-merged child" "closed 0/1" "$(n1_queue_final_finish_state "$U/30")"
# H4 (SEC-1): a child merged into another queue's branch is not landed when the final PR's head is a different branch
# (child-writable Story Branches cell edited to match); nothing is recorded.
mkdir -p "$N1_HOME/queue/q4"; sed -e 's/q3/q4/g' -e 's/R3/R4/g' "$Q3" > "$N1_HOME/queue/q4/queue.md"; Q4="$N1_HOME/queue/q4/queue.md"; E4="$N1_HOME/queue/q4/events.jsonl"
sed -i -e '/^| H-1 /,$ s/| merged |/| pr |/' -e '/^| H-1 | x/ s/| [a-z]* | https/| pr | https/' "$Q4"
echo "{\"event\":\"final_pr_opened\",\"run_id\":\"R4\",\"pr\":\"$U/40\"}" > "$E4"
sed -i "s#$U/30#$U/40#" "$Q4"; echo MERGED > "$T/gh/state.40"; echo queue/q-real > "$T/gh/head.40"
eq "H4: story-branch cell != final PR head" "unlanded" "$(n1_queue_final_landed "$U/40" | awk -F'\t' '$2 == "H-1" { print $1 }')"
eq "H4: no event recorded" 0 "$(jq -c 'select(.event == "ticket_finished")' "$E4" | wc -l | tr -d ' ')"
# H5 (SEC-1): head matches again, but two rows claim the same child PR -> neither lands, nothing recorded
echo queue/q4-x > "$T/gh/head.40"; sed -i "s#$U/32 | s2#$U/31 | s2#" "$Q4"; echo queue/q4-x > "$T/gh/base.31"
eq "H5: duplicate PR rows" "unlanded unlanded" "$(n1_queue_final_landed "$U/40" | awk -F'\t' '$2 == "H-1" || $2 == "H-2" { printf "%s ", $1 }' | sed 's/ $//')"
eq "H5: no event recorded" 0 "$(jq -c 'select(.event == "ticket_finished")' "$E4" | wc -l | tr -d ' ')"
# H6: head matches and PRs are distinct -> the hand-merged child lands
sed -i "s#$U/31 | s2#$U/32 | s2#" "$Q4"
eq "H6: bound to final PR head" "landed" "$(n1_queue_final_landed "$U/40" | awk -F'\t' '$2 == "H-1" { print $1 }')"
# F1: finish_child writes ## Finish, clears the marker, sets step done, runs the queue cleanup
n1_clean_ticket() { echo "clean $1 $2 qdir=${N1_QUEUE_DIR:-}" >> "$T/clean.log"; echo "worktree:removed, branch:deleted"; }
export N1_QUEUE_DIR=/leak
OV="$N1_HOME/memory/T-1/overview.md"; mkdir -p "${OV%/*}"
printf -- '---\nstep: pr\nawaiting: merge\npr: 1\n---\n# T-1\n## Pending\nawaiting: merge\npr: 1\npr_url: %s/1\nlast_checked: x\ncreated: x\n' "$U" > "$OV"
out=$(n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done")
eq "F1: output" "$(printf 'T-1: memory:done\nworktree:removed, branch:deleted')" "$out"
eq "F1: one Finish" 1 "$(grep -cx '## Finish' "$OV")"
eq "F1: Merged line names the final PR" 1 "$(grep -cF -- "- **Merged:** via queue final PR $U/9" "$OV")"
eq "F1: Ticket line" 1 "$(grep -cF -- '- **Ticket:** moved to Done' "$OV")"
eq "F1: child pr_url kept" 1 "$(grep -cx "pr_url: $U/1" "$OV")"
eq "F1: no awaiting" 0 "$(grep -c '^awaiting:' "$OV")"
eq "F1: step done" done "$(n1_read_frontmatter "$OV" step)"
eq "F1: cleanup called without queue env" "clean T-1 queue qdir=" "$(cat "$T/clean.log")"
# F2: rerun is idempotent (one Finish block)
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done" >/dev/null
eq "F2: still one Finish" 1 "$(grep -cx '## Finish' "$OV")"
# F3: invalid id writes nothing; missing memory still cleans
eq "F3: invalid id message" "../x: skipped (invalid ticket id)" "$(n1_queue_finish_child ../x "$U/1" "$U/9" x)"
eq "F3: invalid id rc" 1 "$(n1_queue_finish_child ../x "$U/1" "$U/9" x >/dev/null; echo $?)"
eq "F3: no memory" "T-9: memory:none" "$(n1_queue_finish_child T-9 "$U/1" "$U/9" x | head -n1)"
# F3b: a failed state write stops before cleanup (no frontmatter makes the step write fail)
mkdir -p "$N1_HOME/memory/T-8"; printf 'no frontmatter\n' > "$N1_HOME/memory/T-8/overview.md"; : > "$T/clean.log"
eq "F3b: write failure message" "T-8: memory:failed" "$(n1_queue_finish_child T-8 "$U/1" "$U/9" x | head -n1)"
eq "F3b: write failure rc" 1 "$(n1_queue_finish_child T-8 "$U/1" "$U/9" x >/dev/null; echo $?)"
eq "F3b: no cleanup after failure" "" "$(cat "$T/clean.log")"

# F4 (SEC-2): non-PR URLs are refused before anything is written; the Ticket line is one bounded line
eq "F4: bad child url" "T-1: skipped (invalid PR url)" "$(n1_queue_finish_child T-1 "x
awaiting: merge" "$U/9" x)"
eq "F4: bad final url" 1 "$(n1_queue_finish_child T-1 "$U/1" "javascript:x" x >/dev/null; echo $?)"
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved
awaiting: merge" >/dev/null
eq "F4: newline cannot plant a marker" 0 "$(grep -c '^awaiting:' "$OV")"

# K (N1-462): queue final PR state key from the head ref
out=$(n1_finish_queue_key queue/list-589f8a21-20261115T070604Z); rc=$?
eq "K1: queue head -> key" "queue-list-589f8a21-20261115T070604Z|0" "$out|$rc"
out=$(n1_finish_queue_key feature/N1-1-x); rc=$?
eq "K2: not a queue head" "|1" "$out|$rc"
out=$(n1_finish_queue_key queue/a.b); rc=$?
eq "K3: dotted queue head refused" "|2" "$out|$rc"
out=$(n1_finish_queue_key queue/); rc=$?
eq "K4: empty queue rest refused" "|2" "$out|$rc"
out=$(n1_finish_queue_key 'queue/../x'); rc=$?
eq "K5: traversal refused" "|2" "$out|$rc"

# C (N1-462): a queue-keyed pending delivery is never a covered ticket
G="$T/g"; git init -q "$G"
git -C "$G" -c user.email=t@t -c user.name=t -c commit.gpgSign=false commit -q --allow-empty -m "Queue q1-x: queued tickets (queue-q1-x, N1-9)"
S=$(git -C "$G" rev-parse HEAD)
for d in queue-q1-x N1-9; do mkdir -p "$N1_HOME/memory/$d"; printf -- '---\ndeploy_pending: true\ndeploy_merge_sha: %s\n---\n' "$S" > "$N1_HOME/memory/$d/overview.md"; done
eq "C1: only the ticket is covered, never the queue key" "N1-9 $S ok" "$(cd "$G" && n1_delivery_covered "$S")"
rm -rf "$N1_HOME/memory/queue-q1-x" "$N1_HOME/memory/N1-9"

# F5 (N1-462): the deploy result reaches the child's ## Finish; default and one-line sanitizing
echo MERGED > "$T/gh/state.1"; rm -f "$T/gh/base.1"
OV="$N1_HOME/memory/T-1/overview.md"
printf -- '---\nstep: pr\nawaiting: merge\n---\n# T-1\n' > "$OV"
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done" "succeeded https://github.com/o/r/actions/runs/7" >/dev/null
eq "F5: Deploy line carries the result" 1 "$(grep -cxF -- '- **Deploy:** succeeded https://github.com/o/r/actions/runs/7' "$OV")"
eq "F5: one Finish" 1 "$(grep -cx '## Finish' "$OV")"
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done" >/dev/null
eq "F5: default Deploy line without the arg" 1 "$(grep -cxF -- '- **Deploy:** not watched; delivery not run (queue final PR)' "$OV")"
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done" "failed x
awaiting: merge" >/dev/null
eq "F5: deploy result stays one line" 0 "$(grep -c '^awaiting:' "$OV")"

# S (N1-462): runner Note state after the final PR finish
n1_queue_finish_child T-1 "$U/1" "$U/9" "moved to Done" "none triggered" >/dev/null
eq "S1: finished child counted" "closed 1/1" "$(n1_queue_final_finish_state "$U/9")"
printf -- '---\nstep: pr\nawaiting: merge\n---\n# T-1\n' > "$OV"
eq "S2: unfinished child not counted" "closed 0/1" "$(n1_queue_final_finish_state "$U/9")"
eq "S3: unknown final PR" "closed 0/0" "$(n1_queue_final_finish_state "$U/99")"

echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
