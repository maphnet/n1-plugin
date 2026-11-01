#!/usr/bin/env bash
# tests/test_queue_schedule.sh
# N1-226: scheduled n1-queue runs via Orca automations: policy default, unattended claim, main-checkout unread
# notifier, precheck script (scripts/n1-queue-precheck.sh) and n1_queue_schedule. Fake Orca CLI and fake curl only
# (no live Orca, no tracker). Helpers that consult n1_orca_active run inside $( ) so its per-process cache never leaks.
# Run: bash tests/test_queue_schedule.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 -- $2"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "'$2' not in '$3'";; esac; }
hasnt() { case "$3" in *"$2"*) no "$1" "'$2' unexpectedly in '$3'";; *) ok "$1";; esac; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

LIVE=""
T=$(cd "$(mktemp -d)" && pwd -P); trap '[ -n "$LIVE" ] && kill "$LIVE" 2>/dev/null; rm -rf "$T"' EXIT
export FAKE="$T/fake"; mkdir -p "$FAKE/bin"; : > "$FAKE/calls"

# Fake Orca CLI: logs argv (n1_orca appends --json last), FAKE_* env toggles results.
cat > "$FAKE/bin/fake-orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
ok() { printf '{"id":"1","ok":true,"result":%s}\n' "$1"; }
err() { printf '{"id":"1","ok":false,"error":{"code":"x","message":"%s"}}\n' "$1"; exit 1; }
case "$1 $2" in
  "status --json") [ -n "${FAKE_ORCA_DOWN:-}" ] && err "runtime down"; ok '{"runtime":{"reachable":true}}' ;;
  "worktree set") ok '{}' ;;
  "automations list")
      case "${FAKE_AUTOS:-none}" in
        none) ok '{"automations":[]}' ;;
        one) ok '{"automations":[{"id":"a-1","name":"n1-queue proj","trigger":"daily"},{"id":"a-9","name":"n1-queue other","trigger":"hourly"}]}' ;;
        *) err "boom" ;;
      esac ;;
  "automations create") [ -n "${FAKE_CREATE_FAIL:-}" ] && err "bad trigger"; ok '{"automation":{"id":"a-2"}}' ;;
  "automations remove") [ -n "${FAKE_REMOVE_FAIL:-}" ] && err "locked"; ok '{}' ;;
  *) err "unknown command" ;;
esac
EOF
chmod +x "$FAKE/bin/fake-orca"
export PATH="$FAKE/bin:$PATH" ORCA_CLI_COMMAND="$FAKE/bin/fake-orca"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_HOME="$T/home"; mkdir -p "$N1_HOME/memory"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$T/hh"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset N1_HEADLESS N1_QUEUE_RUN_ID N1_UNATTENDED N1_QUEUE_DIR N1_QUEUE_TAG N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID ORCA_TERMINAL_HANDLE CLAUDE_ENV_FILE
git init -q "$T/proj" && git -C "$T/proj" commit -q --allow-empty -m init && git -C "$T/proj" worktree add -q "$T/wt" -b wt
export CLAUDE_PROJECT_DIR="$T/proj"
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/frontmatter.sh"
source "$REPO_ROOT/lib/queue.sh"
source "$REPO_ROOT/lib/orca-queue.sh"
calls() { cat "$FAKE/calls"; }
reset() { : > "$FAKE/calls"; }

# --- Task 1: policy default, unattended claim, main-checkout unread notifier ---
eq "defaults: unattendedAutoStart false" false "$(jq -r .unattendedAutoStart "$REPO_ROOT/defaults/queue.json")"
eq "policy: default off" false "$(n1_queue_val unattendedAutoStart)"
printf '{"queue":{"unattendedAutoStart":true,"notify":"none"}}\n' > "$N1_HOME/config.json"
eq "policy: config on" true "$(n1_queue_val unattendedAutoStart)"

C="$N1_HOME/queue/c1"
eq "claim: first trigger wins" 0 "$(rc n1_queue_claim "$C")"
eq "claim: overlapping trigger refused" 1 "$(rc n1_queue_claim "$C")"
touch -d '20 minutes ago' "$C/.unattended-claim"
eq "claim: stale claim retaken" 0 "$(rc n1_queue_claim "$C")"
eq "claim: retaken claim is fresh" 1 "$(rc n1_queue_claim "$C")"

eq "main checkout: from main" "$T/proj" "$(n1_main_checkout "$T/proj")"
eq "main checkout: from linked worktree" "$T/proj" "$(n1_main_checkout "$T/wt")"
eq "main checkout: outside git fails" 1 "$(rc n1_main_checkout "$T/home")"

reset
eq "unread: rc 0" 0 "$(CLAUDE_PROJECT_DIR="$T/wt" rc n1_orca_unread_main "T-1 needs you")"
has "unread: marks the main checkout card" "worktree set --worktree path:$T/proj --unread --comment T-1 needs you --json" "$(calls)"
reset; (n1_orca_unread_main "--force") >/dev/null 2>&1
has "unread: option-like text replaced" "--comment n1-queue: needs you" "$(calls)"
reset; (ORCA_CLI_COMMAND= n1_orca_unread_main "T-1 needs you") >/dev/null 2>&1
eq "unread: no Orca -> no call" "" "$(calls)"
reset; (FAKE_ORCA_DOWN=1 n1_orca_unread_main "T-1") >/dev/null 2>&1
hasnt "unread: Orca down -> no set" "worktree set" "$(calls)"
reset; (n1_notify needs-you "T-2 waits for an answer") >/dev/null 2>&1
has "notify needs-you: unread marker" "worktree set --worktree path:$T/proj --unread --comment T-2 waits for an answer" "$(calls)"
reset; (n1_notify done "queue finished") >/dev/null 2>&1
hasnt "notify done: no unread marker" "worktree set" "$(calls)"

# --- Task 2: precheck script ---
PRE="$REPO_ROOT/scripts/n1-queue-precheck.sh"
mkdir -p "$HOME/.config/mcp/secrets"
printf 'ATLASSIAN_URL=https://x.atlassian.net/\nATLASSIAN_EMAIL=me@example.com\nATLASSIAN_TOKEN=s3cr3t-tok\n' > "$HOME/.config/mcp/secrets/jira.env"
cat > "$FAKE/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/curl-argv"
cat >> "$FAKE/curl-stdin"
case "${FAKE_CURL:-zero}" in
  zero) echo '{"issues":[],"isLast":true}' ;;
  one) echo '{"issues":[{"id":"1","key":"TP-1"}],"isLast":false}' ;;
  junk) echo 'not json' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$FAKE/bin/curl"
# Clean env: Orca's precheck env is undocumented, so the script must work with PATH and HOME only.
pre() { env -i PATH="$PATH" HOME="$HOME" FAKE="$FAKE" FAKE_CURL="${FAKE_CURL:-zero}" bash "$PRE" "$N1_HOME" n1-auto "${1:-jira}" TP "To Do"; }
fresh() { rm -rf "$N1_HOME/queue" "$FAKE/curl-argv" "$FAKE/curl-stdin"; mkdir -p "$N1_HOME/queue/n1-auto"; }

fresh; eq "precheck: zero tagged TODO tickets -> skip" 1 "$(rc pre)"
has "precheck: JQL names project, label and status" 'jql=project = "TP" AND labels = "n1-auto" AND status = "To Do"' "$(cat "$FAKE/curl-argv")"
has "precheck: enhanced search endpoint" "https://x.atlassian.net/rest/api/3/search/jql" "$(cat "$FAKE/curl-argv")"
hasnt "precheck: token never in curl argv" "s3cr3t" "$(cat "$FAKE/curl-argv")"
has "precheck: auth header via curl stdin" 'header = "Authorization: Basic ' "$(cat "$FAKE/curl-stdin")"
fresh; eq "precheck: tagged ticket -> start" 0 "$(FAKE_CURL=one rc pre)"
fresh; out=$(FAKE_CURL=fail pre 2>&1); r=$?
eq "precheck: tracker failure fails open" 0 "$r"
has "precheck: failure reason on stderr" "tracker check failed" "$out"
hasnt "precheck: no secret in output" "s3cr3t" "$out"
fresh; eq "precheck: unreadable response fails open" 0 "$(FAKE_CURL=junk rc pre)"
fresh; eq "precheck: missing credentials file fails open" 0 "$(rc pre nope)"
fresh; eq "precheck: non-Jira tracker skips REST" 0 "$(rc pre none)"
eq "precheck: non-Jira tracker never calls curl" no "$([ -s "$FAKE/curl-argv" ] && echo yes || echo no)"

fresh; mkdir "$N1_HOME/queue/n1-auto/.unattended-claim"
eq "precheck: fresh claim -> skip" 1 "$(FAKE_CURL=one rc pre)"
touch -d '20 minutes ago' "$N1_HOME/queue/n1-auto/.unattended-claim"
eq "precheck: stale claim ignored" 0 "$(FAKE_CURL=one rc pre)"

fresh; mkdir -p "$T/p/scripts" "$N1_HOME/queue/other" "$N1_HOME/queue/third"
printf 'sleep 30; :\n' > "$T/p/scripts/n1-queue-run.sh"   # trailing ':' keeps bash from exec-ing sleep
Q="$N1_HOME/queue/other/queue.md"; Q3="$N1_HOME/queue/third/queue.md"
bash "$T/p/scripts/n1-queue-run.sh" "$Q" & LIVE=$!
sleep 0 & DEAD=$!; wait "$DEAD"
sleep 0.3   # let the fake runner exec so /proc/<pid>/cmdline is its own
printf -- '---\nqueue_id: other\nstep: run\npid: %s\n---\n' "$LIVE" > "$Q"
eq "precheck: live runner of any project queue -> skip" 1 "$(FAKE_CURL=one rc pre)"
eq "lib agrees: live runner" 0 "$(rc n1_queue_runner_alive "$LIVE" "$Q")"
printf -- '---\nqueue_id: other\nstep: run\npid: %s\n---\n' "$DEAD" > "$Q"
eq "precheck: dead runner (interrupted run) passes" 0 "$(FAKE_CURL=one rc pre)"
eq "lib agrees: dead runner" 1 "$(rc n1_queue_runner_alive "$DEAD" "$Q")"
printf -- '---\nqueue_id: other\nstep: done\npid: %s\n---\n' "$LIVE" > "$Q"
printf -- '---\nqueue_id: third\nstep: run\npid: %s\n---\n' "$LIVE" > "$Q3"
eq "precheck: runner of another queue file does not count" 0 "$(FAKE_CURL=one rc pre)"
eq "lib agrees: runner of another queue file" 1 "$(rc n1_queue_runner_alive "$LIVE" "$Q3")"
rm -rf "$N1_HOME/queue"

# --- Task 3: n1_queue_schedule ---
reset; out=$(FAKE_AUTOS=none n1_queue_schedule create n1-auto daily Jira jira TP "To Do"); r=$?
eq "schedule create: rc 0" 0 "$r"
has "schedule create: reports automation id" "automation a-2" "$out"
has "schedule create: argv" "automations create --name n1-queue proj --trigger daily --provider claude --workspace path:$T/proj --prompt /n1:n1-queue --tag n1-auto --unattended --precheck bash '$N1_HOME/bin/n1-queue-precheck.sh' '$N1_HOME' 'n1-auto' 'jira' 'TP' 'To Do' --json" "$(calls)"
hasnt "schedule create: nothing removed when absent" "automations remove" "$(calls)"
eq "schedule create: precheck installed" 0 "$(rc cmp -s "$REPO_ROOT/scripts/n1-queue-precheck.sh" "$N1_HOME/bin/n1-queue-precheck.sh")"

reset; out=$(FAKE_AUTOS=one n1_queue_schedule create n1-auto "0 9 * * 1-5" Jira jira TP "To Do")
has "reschedule: removes the existing automation by name" "automations remove a-1 --json" "$(calls)"
hasnt "reschedule: other projects untouched" "remove a-9" "$(calls)"
eq "reschedule: remove before create" "remove create" "$(grep -oE 'automations (remove|create)' "$FAKE/calls" | cut -d' ' -f2 | paste -sd' ' -)"
has "reschedule: cron trigger passed" "--trigger 0 9 * * 1-5 --provider" "$(calls)"

reset; eq "reschedule: remove failure -> rc 1" 1 "$(FAKE_AUTOS=one FAKE_REMOVE_FAIL=1 rc n1_queue_schedule create n1-auto daily Jira jira TP "To Do")"
hasnt "reschedule: remove failure creates nothing" "automations create" "$(calls)"
reset; eq "create: unreadable list -> rc 1" 1 "$(FAKE_AUTOS=fail rc n1_queue_schedule create n1-auto daily Jira jira TP "To Do")"
hasnt "create: unreadable list creates nothing" "automations create" "$(calls)"
reset; eq "create: create failure -> rc 1" 1 "$(FAKE_AUTOS=none FAKE_CREATE_FAIL=1 rc n1_queue_schedule create n1-auto daily Jira jira TP "To Do")"
reset; eq "create: bad tag rejected" 1 "$(rc n1_queue_schedule create "a'b" daily Jira jira TP "To Do")"
eq "create: bad tag never reaches Orca automations" "" "$(grep automations "$FAKE/calls")"
reset; eq "create: bad trigger rejected" 1 "$(rc n1_queue_schedule create n1-auto 'daily$(id)' Jira jira TP "To Do")"
reset; eq "create: quoted TODO status rejected" 1 "$(rc n1_queue_schedule create n1-auto daily Jira jira TP "To'Do")"
reset; out=$(FAKE_AUTOS=none n1_queue_schedule create n1-auto daily YouTrack youtrack TP Open)
has "create: non-Jira tracker -> precheck skips REST" "'n1-auto' 'none' 'TP' 'Open'" "$(calls)"
reset; out=$(FAKE_ORCA_DOWN=1 n1_queue_schedule create n1-auto daily Jira jira TP "To Do")
has "create: Orca down -> message" "not reachable" "$out"
hasnt "create: Orca down -> no automation calls" "automations" "$(calls)"

out=$(FAKE_AUTOS=one n1_queue_schedule list)
has "list: this project's automation" "a-1" "$out"
hasnt "list: other projects hidden" "a-9" "$out"
has "list: none" "No scheduled run for n1-queue proj." "$(FAKE_AUTOS=none n1_queue_schedule list)"
reset; out=$(FAKE_AUTOS=one n1_queue_schedule remove)
has "remove: by looked-up id" "automations remove a-1 --json" "$(calls)"
has "remove: message" "Removed scheduled run a-1" "$out"
has "remove: nothing scheduled" "No scheduled run" "$(FAKE_AUTOS=none n1_queue_schedule remove)"
eq "remove: unreadable list -> rc 1" 1 "$(FAKE_AUTOS=fail rc n1_queue_schedule remove)"
eq "schedule: unknown op -> rc 1" 1 "$(rc n1_queue_schedule frobnicate)"

# --- Task 4: skill wiring (the flag the automation prompt uses must exist in the skill) ---
S="$REPO_ROOT/skills/n1-queue"
has "skill: --unattended in argument-hint" "--unattended" "$(sed -n '1,5p' "$S/SKILL.md")"
has "skill: --schedule routes to schedule.md" "steps/schedule.md" "$(cat "$S/SKILL.md")"
eq "skill: schedule step exists" 0 "$(rc test -f "$S/steps/schedule.md")"
has "run.md: unattended entry section" "## Unattended entry" "$(cat "$S/steps/run.md")"
has "run.md: unattended entry takes the claim" "n1_queue_claim" "$(cat "$S/steps/run.md")"
eq "preview.md: three --unattended answers" 3 "$(grep -c -- '--unattended' "$S/steps/preview.md")"
has "intake.md: unattended repo answer" "--unattended" "$(cat "$S/steps/intake.md")"
has "architecture: scheduled runs section" "### Scheduled queue runs (N1-226)" "$(cat "$REPO_ROOT/references/architecture.md")"

exit "$FAIL"
