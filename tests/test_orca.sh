#!/usr/bin/env bash
# tests/test_orca.sh
# N1-224: Orca workspace helpers (lib/host.sh), ownership/decision (lib/config.sh), start flags,
# step sync, question hook and finish cleanup against a fake Orca CLI (no real Orca).
# Every helper call runs inside $( ) or ( ) so the per-process n1_orca_active cache never leaks between cases.
# Run: bash tests/test_orca.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 -- $2"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "'$2' not in '$3'";; esac; }
hasnt() { case "$3" in *"$2"*) no "$1" "'$2' unexpectedly in '$3'";; *) ok "$1";; esac; }
yn() { "$@" && echo yes || echo no; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export FAKE="$T/fake"; mkdir -p "$FAKE/bin"
: > "$FAKE/calls"; : > "$FAKE/all"
printf '{"ok":true,"result":{"worktrees":[]}}\n' > "$FAKE/worktrees.json"
printf '{"ok":true,"result":{"worktrees":[]}}\n' > "$FAKE/refs.json"

# Fake Orca CLI: logs argv, answers from $FAKE files; FAKE_ORCA_* env toggles failures.
cat > "$FAKE/bin/fake-orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"; printf '%s\n' "$*" >> "$FAKE/all"
ok() { printf '{"id":"1","ok":true,"result":%s}\n' "$1"; }
err() { printf '{"id":"1","ok":false,"error":{"code":"x","message":"%s"}}\n' "$1"; exit 1; }
case "$1 $2" in
  "status --json") [ -n "${FAKE_ORCA_DOWN:-}" ] && err "runtime down"; ok '{"runtime":{"state":"ready","reachable":true}}' ;;
  "worktree list") cat "$FAKE/worktrees.json" ;;
  "worktree set") [ -n "${FAKE_ORCA_SET_FAIL:-}" ] && err "set failed"; ok '{}' ;;
  "worktree create"|"agent launch")
      [ -n "${FAKE_ORCA_CREATE_FAIL:-}" ] && err "create failed"
      [ -n "${FAKE_ORCA_NO_HANDLE:-}" ] && { ok '{"launch":{"outcome":{"kind":"skipped"}}}'; exit 0; }
      [ -n "${FAKE_ORCA_BAD_OUTCOME:-}" ] && { ok '{"worktree":{"path":"/x"},"launch":{"outcome":{"kind":"failed","handle":"term-42"}}}'; exit 0; }
      ok '{"worktree":{"path":"/x"},"launch":{"outcome":{"kind":"journaled","handle":"term-42"}}}' ;;
  "reference find") cat "$FAKE/refs.json" ;;
  "reference add") ok '{}' ;;
  "worktree rm")
      [ -n "${FAKE_ORCA_RM_FAIL:-}" ] && err "rm refused"
      p=""; while [ $# -gt 0 ]; do [ "$1" = --worktree ] && p="${2#path:}"; shift; done
      c=$(cd "$p" && cd "$(git rev-parse --git-common-dir)" && pwd -P) || err "no repo"
      (cd / && git --git-dir="$c" worktree remove --force "$p") || err "git remove failed"
      ok '{}' ;;
  *) err "unknown command" ;;
esac
EOF
# A bare `orca` on PATH records any call: helpers must only ever use $ORCA_CLI_COMMAND.
printf '#!/bin/sh\necho "$*" >> "$FAKE/bare"\nexit 1\n' > "$FAKE/bin/orca"
chmod +x "$FAKE/bin/fake-orca" "$FAKE/bin/orca"
export PATH="$FAKE/bin:$PATH" ORCA_CLI_COMMAND="$FAKE/bin/fake-orca"
export N1_HOME="$T/home"; mkdir -p "$N1_HOME/memory"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset N1_HEADLESS N1_QUEUE_RUN_ID N1_UNATTENDED N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID
source "$REPO_ROOT/lib/config.sh"

calls() { cat "$FAKE/calls"; }
reset() { : > "$FAKE/calls"; }

# Git fixture: main checkout M with origin/main.
M="$T/main"; git init -q -b main "$M"; git -C "$M" commit -q --allow-empty -m init
git init -q --bare "$T/origin.git"; git -C "$M" remote add origin "$T/origin.git"; git -C "$M" push -q origin main
mkdir -p "$T/wts"
wt() { git -C "$M" worktree add -q -b "$2" "$1" main; }          # fresh linked worktree, 0 commits ahead
commit() { git -C "$1" commit -q --allow-empty -m "c-$RANDOM"; }   # one more commit
WO="$T/wts/otter"; wt "$WO" maphskiy/otter; commit "$WO"           # Orca-registered (folder otter, display name X-4)
WN="$M/$(n1_worktree_root)/OTHER-1"; wt "$WN" o1; commit "$WN"     # N1-managed, not registered in Orca

# orca_list <path>[=<displayName>]...: Orca worktree list = main checkout (isMainWorktree) + these.
orca_list() {
    local a p d out
    out=$(jq -cn --arg m "$M" '[{path:$m, displayName:"main", branch:"refs/heads/main", isMainWorktree:true}]')
    for a in "$@"; do
        p="${a%%=*}"; d="${a#*=}"; [ "$a" = "$p" ] && d="${p##*/}"
        out=$(jq -c --arg p "$p" --arg d "$d" '. + [{path:$p, displayName:$d, branch:"refs/heads/x", isMainWorktree:false}]' <<<"$out")
    done
    jq -c '{ok:true,result:{worktrees:.}}' <<<"$out" > "$FAKE/worktrees.json"
}
orca_list "$WO=X-4"

# ---- helpers (lib/host.sh) ----
eq "H1: active with a reachable runtime" yes "$(yn n1_orca_active)"
eq "H2: inactive when the runtime is down" no "$(FAKE_ORCA_DOWN=1 yn n1_orca_active)"
reset; R=$(unset ORCA_CLI_COMMAND; yn n1_orca_active)
eq "H3 (AC7): unset -> inactive" no "$R"
eq "H3 (AC7): unset -> zero CLI calls" "" "$(calls)"
eq "H4: listed non-main worktree is owned" yes "$(yn n1_orca_owns "$WO")"
eq "H4b: unregistered N1-managed worktree is not owned" no "$(yn n1_orca_owns "$WN")"
eq "H4c: main checkout is never owned" no "$(yn n1_orca_owns "$M")"
eq "H4d: display name lookup" X-4 "$(n1_orca_display_name "$WO")"

reset; (cd "$WO" && n1_orca_sync "ticket: done")
has "H5: sync targets the worktree by path" "worktree set --worktree path:$WO --comment ticket: done --json" "$(calls)"
reset; (cd "$WN" && n1_orca_sync "ticket: done")
hasnt "H6: unregistered N1-managed worktree is never touched" "worktree set" "$(calls)"
reset; (cd "$M" && n1_orca_sync "ticket: done")
hasnt "H6b: main checkout card is never touched" "worktree set" "$(calls)"
reset; (cd "$WO" && n1_orca_sync "$(printf 'qa: a\nb\tc')$(printf '%0200d' 0 | tr 0 x)")
C=$(sed -n 's/^worktree set --worktree path:[^ ]* --comment \(.*\) --json$/\1/p' "$FAKE/calls")
eq "H7: comment capped at 120 chars on one line" 120 "${#C}"
has "H7: control chars stripped" "qa: abcxx" "$C"
reset; (cd "$WO" && n1_orca_sync "--force")
hasnt "H8: option-like comment is dropped" "worktree set" "$(calls)"
reset; (cd "$WO" && n1_orca_sync "pr: opened" --status in-review --unread)
has "H9: status passed" "--workspace-status in-review" "$(calls)"
has "H9: unread passed" "--unread" "$(calls)"
reset; (cd "$WO" && n1_orca_sync "pr: opened" --status bogus --status)
hasnt "H10: unknown or missing status dropped" "--workspace-status" "$(calls)"
(cd "$WO" && FAKE_ORCA_SET_FAIL=1 n1_orca_sync "x: y"); eq "H11: CLI failure is best-effort (rc 0)" 0 "$?"

reset; (cd "$WO" && n1_orca_link X-4)
has "H12: link added on an owned worktree" "reference add X-4 --worktree path:$WO --json" "$(calls)"
reset; (cd "$M" && n1_orca_link X-4)
hasnt "H13: no link outside an Orca worktree" "reference add" "$(calls)"
reset; (cd "$WO" && n1_orca_link "-x")
hasnt "H13b: option-like reference dropped" "reference add" "$(calls)"

echo '{"tracker":{"type":"jira"}}' > "$N1_HOME/config.json"
reset; OUT=$(n1_orca_handoff X-1 task create)
eq "H14 (AC1): create handoff ok" "handoff:ok X-1 term-42" "$OUT"
has "H14 (AC1): one named workspace with the Jira reference and a resume prompt" \
    "worktree create --name X-1 --no-parent --reference X-1 --agent claude --prompt /n1:n1-start X-1 --type task --no-handoff --json" "$(calls)"
echo '{"tracker":{"type":"youtrack"}}' > "$N1_HOME/config.json"
reset; (n1_orca_handoff X-1 "" create >/dev/null)
hasnt "H15: no --reference for non-Jira trackers" "--reference" "$(calls)"
has "H15: prompt without --type always carries --no-handoff" "--prompt /n1:n1-start X-1 --no-handoff --json" "$(calls)"
reset; eq "H16: invalid ID rejected" "handoff:failed (invalid ticket id)" "$(n1_orca_handoff 'X-1; rm -rf /' "" create)"
hasnt "H16: no create call for an invalid ID" "worktree create" "$(calls)"
eq "H17: invalid type rejected" "handoff:failed (invalid type)" "$(n1_orca_handoff X-1 'task --evil' create)"
eq "H18: no agent handle -> failed" "handoff:failed (no agent handle in result)" "$(FAKE_ORCA_NO_HANDLE=1 n1_orca_handoff X-1 "" create)"
eq "H18b: prompt outcome other than journaled/handed-to-terminal -> failed (ticket fallback rule)" "handoff:failed (prompt failed)" "$(FAKE_ORCA_BAD_OUTCOME=1 n1_orca_handoff X-1 "" create)"
eq "H19: CLI error -> failed with its reason" "handoff:failed (create failed)" "$(FAKE_ORCA_CREATE_FAIL=1 n1_orca_handoff X-1 "" create)"
reset; eq "H20 (AC2): launch into an existing workspace" "handoff:ok otter term-42" "$(n1_orca_handoff X-4 "" launch "$WO")"
has "H20 (AC2): launch by path selector" "agent launch --worktree path:$WO --agent claude --prompt /n1:n1-start X-4 --no-handoff --json" "$(calls)"
eq "H21: inactive runtime -> failed" "handoff:failed (workspace manager inactive)" "$(FAKE_ORCA_DOWN=1 n1_orca_handoff X-1 "" create)"
rm -f "$N1_HOME/config.json"

# ---- end ----
if [ -e "$FAKE/bare" ]; then no "never bare orca" "$(cat "$FAKE/bare")"; else ok "never bare orca: no call reached an orca on PATH"; fi
hasnt "selector current is never used" "--worktree current" "$(cat "$FAKE/all")"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
