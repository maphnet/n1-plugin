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

exit "$FAIL"
