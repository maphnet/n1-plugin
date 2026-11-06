#!/usr/bin/env bash
# NP-193: intake.md's Candidates Output must define a Reason field, and preview.md's
# plan table header must keep listing Reason -- guards against the two files drifting.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "intake.md Candidates Output lists Reason field" \
    '\*\*Candidates\*\*:.*`Reason`' \
    skills/n1-queue/steps/intake.md
check "intake.md enumerates Reason values (tag match / story subtask)" \
    'tag match.*story subtask' \
    skills/n1-queue/steps/intake.md
check "intake.md enumerates Epic Reason values after story subtask (N1-298)" \
    'story subtask.*epic subtask of <STORY_KEY>.*epic child' \
    skills/n1-queue/steps/intake.md
check "intake.md enumerates the list Reason value (N1-423)" \
    'epic child.*`list` for list-mode candidates' \
    skills/n1-queue/steps/intake.md
check "intake.md expands Done-class Epic children too (N1-298)" \
    'expand every child, including those just classified `done-before-run`' \
    skills/n1-queue/steps/intake.md
check "preview.md plan table header includes Reason column" \
    '\| # \| Ticket \| Title \| Repo \| Model \| Reason \|' \
    skills/n1-queue/steps/preview.md
check "preview.md prints a Hierarchy block for epic rows (N1-298)" \
    '^Hierarchy:$' \
    skills/n1-queue/steps/preview.md
check "preview.md Hierarchy groups rows under their Story (N1-298)" \
    '^Epic <QUEUE_ID> > Story <STORY_KEY> <CHILD_TITLE>: #' \
    skills/n1-queue/steps/preview.md
check "preview.md prints the Concurrency line (N1-272)" \
    'Concurrency: <MAX_CONCURRENT> \(queue\.maxConcurrent' \
    skills/n1-queue/steps/preview.md
check "preview.md usage note only when MAX_CONCURRENT is above 1 (N1-272)" \
    'when `MAX_CONCURRENT` is above 1 append ` Parallel workers share your usage limits\.`' \
    skills/n1-queue/steps/preview.md
check "run.md stale-plan prompt usage note only when MAX_CONCURRENT is above 1 (N1-272)" \
    'when `MAX_CONCURRENT` is above 1 append ` Parallel workers share your usage limits\.`' \
    skills/n1-queue/steps/run.md
check "preview.md prints the resolved selector header (N1-440)" \
    '^Mode: <list\|tag\|story> \| Source: <ticket keys, tag or story ID> \| Candidates: <N>$' \
    skills/n1-queue/steps/preview.md
check "preview.md advances planning state to preview (N1-440)" \
    'n1_queue_plan_state step preview' \
    skills/n1-queue/steps/preview.md
check "preview.md dry-run discards the planning dir (N1-440)" \
    '^If `--dry-run`: print "Dry run -- nothing launched\.", run § Discard' \
    skills/n1-queue/steps/preview.md
check "preview.md Cancel discards the planning dir (N1-440)" \
    '^- \*\*Cancel\*\* -> run § Discard, then \*\*STOP\.\*\*' \
    skills/n1-queue/steps/preview.md
check "preview.md discard calls n1_queue_plan_discard (N1-440)" \
    "n1_queue_plan_discard '<QUEUE_ID>'" \
    skills/n1-queue/steps/preview.md
ln_of() { grep -nE -- "$1" skills/n1-queue/steps/preview.md | head -1 | cut -d: -f1; }
H=$(ln_of '^Mode: <list'); D=$(ln_of '^If `--dry-run`'); P=$(ln_of '^## Plan-Resolve$'); S=$(ln_of 'n1_queue_plan_state step plan-resolve'); W=$(ln_of '^### 1\. Brief')
if [ -n "$H" ] && [ -n "$D" ] && [ -n "$P" ] && [ -n "$S" ] && [ -n "$W" ] && [ "$H" -lt "$D" ] && [ "$D" -lt "$P" ] && [ "$P" -lt "$S" ] && [ "$S" -lt "$W" ]; then
    echo "PASS: header precedes dry-run stop; plan-resolve state precedes the first tracker write (N1-440)"
else echo "FAIL: header precedes dry-run stop; plan-resolve state precedes the first tracker write (N1-440)"; FAIL=1; fi

exit $FAIL
