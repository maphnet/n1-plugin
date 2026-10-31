#!/usr/bin/env bash
# tests/test_orca.sh
# N1-224: Orca workspace helpers (lib/host.sh), ownership/decision (lib/config.sh), start flags,
# step sync, question hook and finish cleanup against a fake Orca CLI (no real Orca).
# AC8 live check on test-project is DEFERRED: Orca 1.4.243 is installed, 1.4.244 is required, so no live run
# (handoff create/launch, card sync, finish removal with .env, create-result handle path, `path` vs
# `git rev-parse --show-toplevel`) has been done; everything here is fake-CLI only. No live evidence exists.
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

# ---- ownership + decision (lib/config.sh) ----
orca_list "$WO=X-4"
dec() { local d="$1"; shift; (cd "$d" && n1_workspace_decide "$@"); }
noorca() { (unset ORCA_CLI_COMMAND; "$@"); }
eq "B1: N1-22 does not match N1-224" no "$(yn _n1_id_in N1-22 n1-224-x)"
eq "B2: branch token match is case-insensitive" yes "$(yn _n1_id_in N1-224 feat/n1-224-thing)"
eq "B3: no match inside a longer token" no "$(yn _n1_id_in N1-224 xn1-224)"
eq "B4: no match when letters follow the ID" no "$(yn _n1_id_in N1-224 feat/N1-224extra)"
eq "B5: - and _ after the ID still match" yes "$(yn _n1_id_in N1-224 feat/N1-224_x)"

eq "D1 (AC7): main, none, no Orca -> create-local" create-local "$(noorca dec "$M" Z-1)"
reset; noorca dec "$M" Z-1 >/dev/null
eq "D1 (AC7): no Orca -> zero CLI calls" "" "$(calls)"
eq "D2 (AC1): main, none, Orca -> handoff-create" handoff-create "$(dec "$M" Z-2)"
eq "D2b: headless never hands off" create-local "$(N1_HEADLESS=1 dec "$M" Z-2)"
eq "D2c: queue child never hands off" create-local "$(N1_QUEUE_RUN_ID=q1 dec "$M" Z-2)"
eq "D2d: --no-handoff never hands off" create-local "$(dec "$M" Z-2 --no-handoff)"
eq "D2e (AC7): runtime down -> create-local" create-local "$(FAKE_ORCA_DOWN=1 dec "$M" Z-2)"
W3="$T/wts/X-3"; wt "$W3" maphskiy/fox; commit "$W3"
eq "D3: main + git worktree named like the ticket -> reuse" "reuse $W3" "$(noorca dec "$M" X-3)"
eq "D3b: found worktree not registered in Orca -> plain reuse" "reuse $W3" "$(dec "$M" X-3)"
eq "D4 (AC2): main + Orca workspace by display name -> handoff-launch" "handoff-launch $WO" "$(dec "$M" X-4)"
eq "D4b (AC2): headless reuses the path" "reuse $WO" "$(N1_HEADLESS=1 dec "$M" X-4)"
eq "D4c: N1-managed worktree found by basename -> reuse" "reuse $WN" "$(dec "$M" OTHER-1)"
printf '{"ok":true,"result":{"path":"%s"}}\n' "$WO" > "$FAKE/refs.json"
eq "D4d (SEC-2): fuzzy reference hit for another ticket's folder is ignored" handoff-create "$(dec "$M" X-9)"
printf '{"ok":true,"result":{"worktrees":[]}}\n' > "$FAKE/refs.json"
eq "D5: inside a worktree named like the ticket -> stay" "stay $W3" "$(noorca dec "$W3" X-3)"
eq "D5b (AC2): inside the Orca workspace (display name) -> stay" "stay $WO" "$(dec "$WO" X-4)"
W6="$T/wts/w6"; wt "$W6" feat/X-6-thing; commit "$W6"
eq "D6: branch contains the ID -> stay" "stay $W6" "$(noorca dec "$W6" X-6)"
eq "D7 (AC3): another ticket's worktree with commits -> ask" "ask $W6 feat/X-6-thing" "$(noorca dec "$W6" Y-7)"
eq "D7b (AC3): N1-managed worktree of another ticket -> ask (Gap 1 everywhere)" "ask $WN o1" "$(noorca dec "$WN" Y-7)"
W8="$T/wts/w8"; wt "$W8" b8
eq "D8 (AC3): fresh empty worktree -> stay silently" "stay $W8" "$(noorca dec "$W8" Y-8)"
W8b="$T/wts/w8b"; wt "$W8b" b8b; echo wip > "$W8b/wip.txt"
eq "D8b: fresh worktree with uncommitted work -> ask, not adopted" "ask $W8b b8b" "$(noorca dec "$W8b" Y-8)"
mkdir -p "$N1_HOME/memory/Y-9"; printf -- '---\nworkspace_path: %s\n---\n' "$W6" > "$N1_HOME/memory/Y-9/overview.md"
eq "D9: overview workspace_path points here -> stay" "stay $W6" "$(noorca dec "$W6" Y-9)"
eq "D9b: overview workspace_path found from main -> reuse" "reuse $W6" "$(noorca dec "$M" Y-9)"
M2="$T/m2"; git init -q -b main "$M2"; git -C "$M2" commit -q --allow-empty -m init; git -C "$M2" worktree add -q -b b10 "$T/w10" main
eq "D10: no origin ref -> local default fallback" "stay $T/w10" "$(noorca dec "$T/w10" Y-10)"
eq "D11: --elsewhere skips the ownership check" create-local "$(noorca dec "$W6" Y-7 --elsewhere)"

# ---- start flags (lib/validation.sh) ----
source "$REPO_ROOT/lib/validation.sh"
pf() { n1_parse_start_flags "$1"; printf '%s|%s|%s' "$TYPE_OVERRIDE" "$NO_HANDOFF" "$USER_INPUT"; }
eq "P1: trailing --no-handoff" "|true|N1-1" "$(pf 'N1-1 --no-handoff')"
eq "P2: --type then --no-handoff" "task|true|N1-1" "$(pf 'N1-1 --type task --no-handoff')"
eq "P3: --no-handoff then --type" "task|true|N1-1" "$(pf 'N1-1 --no-handoff --type task')"
eq "P4: --type only" "bug|false|N1-1" "$(pf 'N1-1 --type bug')"
eq "P5: mid-text flag in a brain dump stays text" "|false|fix the --no-handoff flag in docs" "$(pf 'fix the --no-handoff flag in docs')"

# ---- step sync + question hook (AC5) ----
source "$REPO_ROOT/lib/step.sh"
reset; (cd "$WO" && ID=X-4 n1_step_end review 7 escalated) >/dev/null 2>&1
has "S1 (AC5): step end updates the card" "--comment review: escalated" "$(calls)"
has "S1 (AC5): escalation sets unread" "--unread" "$(calls)"
reset; (cd "$WO" && ID=X-4 n1_step_end qa 6 success) >/dev/null 2>&1
has "S2 (AC5): success comment" "--comment qa: success --json" "$(calls)"
hasnt "S2: no unread on success" "--unread" "$(calls)"
reset; (unset ORCA_CLI_COMMAND; cd "$WO" && ID=X-4 n1_step_end qa 6 success) >/dev/null 2>&1
eq "S3 (AC7): no CLI calls when unset" "" "$(calls)"

mkdir -p "$N1_HOME/memory/X-4"; printf -- '---\nstep: plan\n---\n' > "$N1_HOME/memory/X-4/overview.md"
printf '{"ticketId":"X-4","runId":"r","worktreePath":"%s","branch":"maphskiy/otter"}\n' "$WO" > "$N1_HOME/active-run.s1.json"
echo '{"notify":{"onQuestion":false}}' > "$N1_HOME/config.json"
reset
jq -cn --arg cwd "$WO" '{session_id:"s1",cwd:$cwd,tool_name:"AskUserQuestion"}' | bash "$REPO_ROOT/hooks/notify-question.sh"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q -- '--unread' "$FAKE/calls" && break; sleep 0.25; done
has "Q1 (AC5): question pause sets unread even with desktop notify off" "--comment waiting: plan --unread" "$(calls)"
rm -f "$N1_HOME/config.json" "$N1_HOME/active-run.s1.json"

# ---- finish cleanup: Orca-owned worktrees (AC6) ----
fin() {   # fin <path> <branch>: merged worktree with an ignored .env
    git -C "$M" worktree add -q -b "$2" "$1" main
    printf '.env\n' > "$1/.gitignore"; git -C "$1" add .gitignore; git -C "$1" commit -q -m "$2"
    git -C "$M" merge -q --no-ff -m "m-$2" "$2"; echo secret > "$1/.env"
}
run_fc() { (cd "$1" && n1_finish_cleanup "$2" "$(git -C "$M" rev-parse "$2")" main) | paste -sd, -; }
F1="$T/wts/fin1"; fin "$F1" fb1
F2="$T/wts/fin2"; fin "$F2" fb2; echo x > "$F2/untracked"
F3="$T/wts/fin3"; fin "$F3" fb3
orca_list "$WO=X-4" "$F1" "$F2" "$F3"
reset; eq "F1 (AC6): merged Orca worktree with .env removed" "worktree:removed,branch:deleted" "$(run_fc "$F1" fb1)"
has "F1 (AC6): removed through the workspace manager" "worktree rm --worktree path:$F1 --json" "$(calls)"
eq "F1 (AC6): dir gone" no "$([ -d "$F1" ] && echo yes || echo no)"
reset; eq "F2: dirty Orca worktree kept" "worktree:kept (dirty),branch:kept (worktree kept)" "$(run_fc "$F2" fb2)"
hasnt "F2: no removal call" "worktree rm" "$(calls)"
eq "F3: Orca rm failure reported, no git fallback" "worktree:remove-failed (rm refused),branch:kept (worktree kept)" "$(FAKE_ORCA_RM_FAIL=1 run_fc "$F3" fb3)"
eq "F3: dir kept" yes "$([ -d "$F3" ] && echo yes || echo no)"
F4="$M/$(n1_worktree_root)/fin4"; fin "$F4" fb4; echo x > "$F4/untracked"
F5="$M/$(n1_worktree_root)/fin5"; fin "$F5" fb5
orca_list "$WO=X-4" "$F4" "$F5"
reset; eq "F4: dirty Orca worktree under the N1 root is kept, not forced" "worktree:kept (dirty),branch:kept (worktree kept)" "$(run_fc "$F4" fb4)"
eq "F4: dir kept" yes "$([ -d "$F4" ] && echo yes || echo no)"
reset; eq "F5: Orca worktree under the N1 root removed through Orca" "worktree:removed,branch:deleted" "$(run_fc "$F5" fb5)"
has "F5: removal goes through the workspace manager" "worktree rm --worktree path:$F5 --json" "$(calls)"

# ---- static wiring ----
cd "$REPO_ROOT"
eq "W1 (AC4): only n1-start decides or hands off workspaces" "" "$(grep -rlE 'n1_workspace_decide|n1_orca_handoff' skills agents | grep -v '^skills/n1-start/' || true)"
has "W2 (AC1): ticket step runs the workspace decision" "Workspace Decision" "$(cat skills/n1-start/steps/ticket.md)"
TK=skills/n1-start/steps/ticket.md
ln() { grep -n -m1 -F "$1" "$TK" | cut -d: -f1; }
eq "W2b: no worktree creation before overview.md exists" yes "$(yn test -z "$(grep -F 'Ensure Worktree' "$TK")")"
eq "W2c (CR-2): Assign values are read before the workspace step, which comes before the step close" yes \
    "$(yn test "$(ln 'n1_assign_gap_warn')" -lt "$(ln '**Workspace**')" -a "$(ln '**Workspace**')" -lt "$(ln 'n1_step_end "ticket" 1 success')")"
has "W2e: Adopt Checkout syncs and links the card from inside the adopted checkout" '(cd "$WORKTREE_PATH" && n1_orca_sync "ticket: in progress"' "$(cat skills/n1-start/procedures/workspace-isolation.md)"
has "W2d (CR-7): handoff snippet sets FRESH itself and gates the step pre-write on it" 'FRESH=<1|0>; [ "$FRESH" = 1 ] && n1_write_frontmatter' "$(cat skills/n1-start/procedures/workspace-ownership.md)"
has "W3 (AC1): input parsing uses n1_parse_start_flags" "n1_parse_start_flags" "$(cat skills/n1-start/procedures/input-parsing.md)"
has "W4 (AC5): n1-pr marks the card in review" 'n1_orca_sync "pr: opened" --status in-review' "$(cat skills/n1-pr/steps/02-push-create.md)"
has "W5 (AC5): n1-finish marks only this ticket's card completed" '[ -n "$HR" ] && [ "$BR" = "$HR" ] && n1_orca_sync "finish: merged" --status completed' "$(cat skills/n1-finish/steps/06-cleanup.md)"
has "W6 (AC3): ownership prompt carries the no-recommendation sentence" \
    "No recommendation. The options are equivalent given the available evidence; select based on team preference." "$(cat skills/n1-start/procedures/workspace-ownership.md 2>/dev/null)"
hasnt "W6b: ownership prompt has no (Recommended) option" "(Recommended)" "$(cat skills/n1-start/procedures/workspace-ownership.md 2>/dev/null)"
cd - >/dev/null

# ---- end ----
if [ -e "$FAKE/bare" ]; then no "never bare orca" "$(cat "$FAKE/bare")"; else ok "never bare orca: no call reached an orca on PATH"; fi
hasnt "selector current is never used" "--worktree current" "$(cat "$FAKE/all")"
[ "$FAIL" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $FAIL
