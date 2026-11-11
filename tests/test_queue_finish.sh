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
# fake gh: "gh pr view --json state -q .state -- <url>" prints $T/gh/state.<num>; no file -> exit 1
printf '#!/usr/bin/env bash\nu="${@: -1}"; f="%s/gh/state.${u##*/}"; [ -f "$f" ] && cat "$f" || exit 1\n' "$T" > "$T/bin/gh"
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
for n in 1 3 4 5; do echo MERGED > "$T/gh/state.$n"; done

# L1: landed / unlanded split for the final PR's repo only (T-3 is another repo's final PR)
out=$(n1_queue_final_landed "$U/9"); rc=$?
eq "L1: rc 0" 0 "$rc"
eq "L1: lines" "$(printf 'queue %s\nlanded\tT-1\t%s/1\nunlanded\tT-2\tfailed\nunlanded\tT-4\tother N1 Home\nunlanded\t-\tinvalid ticket id' "$Q" "$U")" "$out"
# L2: a child PR that is not MERGED is not landed
echo OPEN > "$T/gh/state.1"
eq "L2: open child PR" "$(printf 'unlanded\tT-1\tchild PR not merged')" "$(n1_queue_final_landed "$U/9" | grep T-1)"
echo MERGED > "$T/gh/state.1"
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

echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
