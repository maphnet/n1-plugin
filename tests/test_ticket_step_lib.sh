#!/usr/bin/env bash
# N1-476: lib/ticket-step.sh runs the ticket step's intake, post-agent and envelope blocks; ticket.md's fences call them.
# Run: bash tests/test_ticket_step_lib.sh
set -o pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/ticket-step.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_QUEUE_RUN_ID N1_HEADLESS N1_STORY_ID
export N1_HOME="$T/home" ID="TK-1" N1_SESSION_ID=test-session
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM"
ret() { # <intake-result json> [tier line]
    printf '%s\n' "intake-result: $1" "${2-tier: complex}" 'title: Fix "quoted" $(title) here' 'brief: x' \
        'n1:signals task_type=bug description_quality=adequate' > "$MEM/ticket-return.md"; }
BUG='{"title":"Login fails","tags":[],"type":"bug","issue_type":"Task","subtask_count":0,"is_investigation":false,"original_status":"Open"}'

# --- n1_ticket_intake ---
: > "$MEM/ticket.md"; ret "$BUG"
OUT=$(n1_ticket_intake '' 2>&1)
has "intake: title from intake-result" "$OUT" "TITLE=Login fails"
has "intake: type field resolves" "$OUT" "RESOLVED_TYPE=bug"
has "intake: matched by type field" "$OUT" "TYPE_MATCHED_BY=type_field"
has "intake: original status" "$OUT" "ORIGINAL_STATUS=Open"
has "intake: not a story" "$OUT" "IS_STORY=false"
has "intake: env read for the brief" "$OUT" $'QUEUE_RUN_ID=\nHEADLESS='
has "intake: valid override wins" "$(n1_ticket_intake investigation 2>&1)" "RESOLVED_TYPE=investigation"
has "intake: override marks investigation" "$(n1_ticket_intake investigation 2>&1)" "INVESTIGATION_DETECTED=true"
has "intake: unsubstituted placeholder override ignored" "$(n1_ticket_intake '<TYPE_OVERRIDE from input parsing, empty if none>' 2>&1)" "RESOLVED_TYPE=bug"
ret '{"title":"E","tags":[],"type":"task","issue_type":"Epic","subtask_count":0,"original_status":""}'
has "intake: epic is a story" "$(n1_ticket_intake '' 2>&1)" "IS_STORY=true"
ret '{"title":"P","tags":[],"type":"task","issue_type":"Task","subtask_count":3,"original_status":""}'
has "intake: task with sub-tasks is a story" "$(n1_ticket_intake '' 2>&1)" "IS_STORY=true"
ret '{"title":"Crash","tags":[],"type":"task","linked_error":{"provider":"sentry","issueId":"1","issueUrl":"https://s.example/issues/1"},"issue_type":"unknown","subtask_count":0,"original_status":""}'
OUT=$(n1_ticket_intake '' 2>&1)
has "intake: linked error url" "$OUT" "LINKED_ERROR_URL=https://s.example/issues/1"
has "intake: linked error forces bug" "$OUT" "RESOLVED_TYPE=bug"
for TAGS in '"tags":["chore"]' '"tags": ["chore"]' '"tags": [ "x" , "chore" ]' '"tags" : ["chore"]'; do
    ret '{"title":"T",'"$TAGS"',"type":"task","issue_type":"Task","subtask_count":0,"original_status":""}'
    OUT=$(n1_ticket_intake '' 2>&1)
    has "intake: tags $TAGS resolves" "$OUT" "RESOLVED_TYPE=chore"
    has "intake: tags $TAGS matched by tags" "$OUT" "TYPE_MATCHED_BY=tags"
done
rm -f "$MEM/ticket-return.md"
has "intake: no return file -> default task" "$(n1_ticket_intake '' 2>&1)" "RESOLVED_TYPE=task"

# --- n1_ticket_persist ---
printf -- '---\n---\n' > "$MEM/overview.md"; printf 'x\n' > "$MEM/ticket.md"; printf 'convert\n' > "$MEM/.story-convert"
ret "$BUG"
OUT=$(n1_ticket_persist '' 2>&1)
has "persist: tier from the return" "$OUT" "TIER=complex"
has "persist: session name keeps title text literal" "$OUT" 'SESSION_NAME=TK-1 Fix "quoted" $(title) here'
has "persist: assign config printed" "$OUT" "ASSIGN_OP="
eq "persist: tier frontmatter" "complex" "$(n1_read_frontmatter "$MEM/overview.md" tier)"
eq "persist: type frontmatter" "bug" "$(n1_read_frontmatter "$MEM/overview.md" type)"
eq "persist: type_matched_by frontmatter" "type_field" "$(n1_read_frontmatter "$MEM/overview.md" type_matched_by)"
eq "persist: original_status frontmatter" "Open" "$(n1_read_frontmatter "$MEM/overview.md" original_status)"
eq "persist: story_convert frontmatter" "convert" "$(n1_read_frontmatter "$MEM/overview.md" story_convert)"
eq "persist: .story-convert consumed" "no" "$([ -e "$MEM/.story-convert" ] && echo yes || echo no)"
eq "persist: return signals written to ticket.md" "bug" "$(n1_read_signal "$MEM/ticket.md" task_type)"
eq "persist: ticket context carries the type" "bug" "$( . "$MEM/ticket-context.sh"; echo "$TYPE")"
ret "$BUG" ''
has "persist: missing tier defaults to standard" "$(n1_ticket_persist '' 2>&1)" "TIER=standard"
ret "$BUG" 'tier: simple'
has "persist: valid tier passes through" "$(n1_ticket_persist '' 2>&1)" "TIER=simple"
ret "$BUG" 'tier: x"; touch '"$T"'/pwned; "\n'
has "persist: hostile tier falls back to standard" "$(n1_ticket_persist '' 2>&1)" "TIER=standard"
eq "persist: hostile tier frontmatter clean" "standard" "$(n1_read_frontmatter "$MEM/overview.md" tier)"
eq "persist: hostile tier context clean" "standard" "$( . "$MEM/ticket-context.sh"; echo "$TIER")"
eq "persist: hostile tier not executed" "no" "$([ -e "$T/pwned" ] && echo yes || echo no)"
# Reconcile Memory ID & Branch moves the whole memory dir: the persist call reads ticket-return.md under the new ID.
ret "$BUG"; mv "$MEM" "$N1_HOME/memory/TK-2"
OUT=$(ID=TK-2 n1_ticket_persist '' 2>&1)
has "persist: return file follows the reconciled memory dir" "$OUT" "SESSION_NAME=TK-2 Fix"
mv "$N1_HOME/memory/TK-2" "$MEM"

# --- n1_ticket_envelope ---
mkdir -p "$MEM/telemetry/raw/steps"
( N1_RUN_ID=run-tk N1_VERSION=9.9.9 BRANCH=b; n1_ticket_envelope )
eq "envelope: config_snapshot written" "true" "$(jq -r '.config_snapshot.plan_review_enabled' "$MEM/telemetry/raw/steps/run-tk.jsonl")"
eq "envelope: local testing defaults to true" "true" "$(jq -r '.config_snapshot.local_testing_enabled' "$MEM/telemetry/raw/steps/run-tk.jsonl")"
( unset N1_RUN_ID; n1_ticket_envelope ); eq "envelope: no run id -> no write" "1" "$(cat "$MEM"/telemetry/raw/steps/*.jsonl | wc -l | tr -d ' ')"

# --- ticket_url writer (CR-5): any run that ends with a tracker ID ---
printf -- '---\n---\n' > "$MEM/overview.md"; ret "$BUG"
echo '{"tracker":{"type":"jira"}}' > "$N1_HOME/config.json"
echo 'https://x.atlassian.net/' > "$MEM/instance-url.txt"; n1_ticket_persist '' >/dev/null 2>&1
eq "ticket_url: jira base_url -> /browse/<ID>" "https://x.atlassian.net/browse/TK-1" "$(n1_read_frontmatter "$MEM/overview.md" ticket_url)"
eq "ticket_url: instance-url.txt consumed" "no" "$([ -f "$MEM/instance-url.txt" ] && echo yes || echo no)"
echo '{"tracker":{"type":"youtrack"}}' > "$N1_HOME/config.json"
echo 'https://yt.example.com' > "$MEM/instance-url.txt"; n1_ticket_persist '' >/dev/null 2>&1
eq "ticket_url: youtrack -> /issue/<ID>" "https://yt.example.com/issue/TK-1" "$(n1_read_frontmatter "$MEM/overview.md" ticket_url)"
printf -- '---\n---\n' > "$MEM/overview.md"; echo 'https://x.com/$(id)' > "$MEM/instance-url.txt"; n1_ticket_persist '' >/dev/null 2>&1
eq "ticket_url: URL with shell characters is not written" "" "$(n1_read_frontmatter "$MEM/overview.md" ticket_url)"
STEP="$REPO_ROOT/skills/n1-start/steps/ticket.md"
has "ticket.md: Ticket URL block covers created tickets" "$(grep '^\*\*Ticket URL' "$STEP")" "just created"
has "ticket.md: URL goes through instance-url.txt" "$(grep '^\*\*Ticket URL' "$STEP")" "instance-url.txt"

# --- step wiring: run ticket.md's own fences ---
STEP="$REPO_ROOT/skills/n1-start/steps/ticket.md"
fence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1" | sed '/^source /d'; }
rawfence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1"; }
n1_step_begin() { :; }; n1_step_end() { :; }
for N in 1 2 3; do has "wiring: ticket fence $N sources the lib" "$(rawfence "$STEP" $N)" 'source "$N1_ROOT/lib/ticket-step.sh"'; done
eq "wiring: ticket.md has 3 bash fences" "3" "$(grep -c '^```bash$' "$STEP")"
ret "$BUG"
has "wiring: intake fence resolves the type" "$( eval "$(fence "$STEP" 1)" 2>&1 )" "RESOLVED_TYPE=bug"
has "wiring: persist fence prints the session name" "$( eval "$(fence "$STEP" 2)" 2>&1 )" "SESSION_NAME=TK-1"
has "wiring: close fence ends the step" "$(fence "$STEP" 3)" 'n1_step_end "ticket" 1 success'

exit $FAIL
