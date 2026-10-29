#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_VERSION N1_TRANSCRIPT_PATH N1_PARENT_SESSION_ID CLAUDE_CODE_SESSION_ID
export N1_HOME="$T/project" N1_STATE_DIR="$T/state"
source "$ROOT/lib/telemetry.sh"

# n1_host is a constant and n1_worktree_root falls back to the default even
# with no host or plugin-root evidence in the env (NP-155/NP-228 regression).
RES=$(env -u N1_HOST -u CLAUDE_PLUGIN_ROOT bash -c "source '$ROOT/lib/host.sh'; n1_host; echo; n1_worktree_root")
test "$(printf '%s' "$RES" | sed -n '1p')" = "claude-code"
test "$(printf '%s' "$RES" | sed -n '2p')" = ".claude/worktrees"
echo 'PASS: constant host and default worktree root with no env evidence'

export N1_SESSION_ID=thread-a
ID=NP-A
n1_run_begin "$ID"
A="$N1_RUN_ID"
export N1_SESSION_ID=thread-b
ID=NP-B
n1_run_begin "$ID"
B="$N1_RUN_ID"
export N1_SESSION_ID=thread-a
unset N1_RUN_ID
n1_read_lock "$N1_HOME/memory"
test "$N1_LOCK_RUN_ID" = "$A"
export N1_SESSION_ID=thread-missing
if n1_read_lock "$N1_HOME/memory"; then echo 'foreign lock selected' >&2; exit 1; fi
export N1_SESSION_ID=thread-a
# Another session starting in the same ticket cannot steal this session's lock.
export N1_SESSION_ID=thread-c
n1_run_begin NP-A
export N1_SESSION_ID=thread-a
unset N1_RUN_ID
n1_read_lock "$N1_HOME/memory"
test "$N1_LOCK_RUN_ID" = "$A"
python3 - "$N1_HOME/memory/NP-A/telemetry/raw/steps/$A.jsonl" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).readline())
assert row['host'] == 'claude-code' and row['session_id'] == 'thread-a'
assert row['run_id'] and row['started_at']
PY
echo 'PASS: concurrent run/session isolation'
# Same-session overlapping runs require an explicit run, not latest-mtime.
n1_run_begin NP-A
SECOND="$N1_RUN_ID"
unset N1_RUN_ID
if n1_read_lock "$N1_HOME/memory"; then echo 'ambiguous same-session run selected' >&2; exit 1; fi
export N1_RUN_ID="$SECOND"
n1_read_lock "$N1_HOME/memory"
test "$N1_LOCK_RUN_ID" = "$SECOND"
echo 'PASS: ambiguous same-session run rejected'

# --- n1_restore_run_identity (N1-32) ---
R="$T/restore"; mkdir -p "$R"
restore() { # <session> [pre-set run id]; prints "<run>|<version>|<exported-in-child>"
    ( unset N1_RUN_ID N1_VERSION; [ -z "${2:-}" ] || N1_RUN_ID="$2"
      export N1_HOME="$R/home" N1_SESSION_ID="$1"
      source "$ROOT/lib/telemetry.sh"; n1_restore_run_identity
      printf '%s|%s|%s' "${N1_RUN_ID:-}" "${N1_VERSION:-}" "$(bash -c 'printf %s "${N1_RUN_ID:-}"')" )
}
mklock() { # <ticket> <run> <session>
    mkdir -p "$R/home/memory/$1/telemetry/locks"
    printf '{"run_id":"%s","n1_version":"9.9.9","session_id":"%s","host":"claude-code"}\n' "$2" "$3" > "$R/home/memory/$1/telemetry/locks/$2.json"
}
pointer() { printf '{"ticketId":"%s","runId":"%s","worktreePath":null,"branch":""}\n' "${3:-X}" "$2" > "$R/home/active-run.$1.json"; }
mkdir -p "$R/home"
mklock NP-R n1-run-restore sess-r; pointer sess-r n1-run-restore
test "$(restore sess-r)" = "n1-run-restore|9.9.9|"      # restored, not exported
test "$(restore '')" = "||"                              # no session
test "$(restore sess-r n1-run-preset)" = "n1-run-preset||"  # preset id untouched
mklock NP-S n1-run-other sess-other; pointer sess-s n1-run-other
test "$(restore sess-s)" = "||"                          # lock session mismatch
pointer sess-n none; test "$(restore sess-n)" = "||"
pointer sess-f n1-finish; test "$(restore sess-f)" = "||"
mv "$R/home/memory/NP-R" "$R/home/memory/NP-R2"          # reconcile renamed the memory dir
test "$(restore sess-r)" = "n1-run-restore|9.9.9|"
pointer sess-t 'n1-run-a/../b'; test "$(restore sess-t)" = "||"   # traversal rejected
pointer sess-t 'n1-run-"abc'; test "$(restore sess-t)" = "||"     # bad first suffix char (quote)
pointer sess-t 'n1-run-/abc'; test "$(restore sess-t)" = "||"     # bad first suffix char (slash)
mklock NP-V n1-run-badver sess-v; pointer sess-v n1-run-badver
printf '{"run_id":"n1-run-badver","n1_version":"1\\"x","session_id":"sess-v"}\n' > "$R/home/memory/NP-V/telemetry/locks/n1-run-badver.json"
test "$(restore sess-v)" = "n1-run-badver||"              # bad version dropped
echo 'PASS: restore run identity'

# Preamble wiring: sourcing lib/preamble.sh restores identity and step events land in <run>.jsonl
PW=$(env -i HOME="$HOME" PATH="$PATH" N1_ROOT="$ROOT" N1_HOME="$R/home" N1_SESSION_ID=sess-r bash -c \
    "source '$ROOT/lib/preamble.sh' >/dev/null 2>&1; ID=NP-R2; n1_step_begin ticket 1 >/dev/null 2>&1; printf '%s|%s' \"\${N1_RUN_ID:-}\" \"\${N1_VERSION:-}\"")
test "$PW" = "n1-run-restore|9.9.9"
test -s "$R/home/memory/NP-R2/telemetry/raw/steps/n1-run-restore.jsonl"
test ! -e "$R/home/memory/NP-R2/telemetry/raw/steps/.jsonl"
echo 'PASS: preamble restores run identity'

# --- n1_bind_run_to_ticket: two tickets in one session overwrite the pointer (N1-193) ---
mklock NP-TA n1-run-ta sess-2; pointer sess-2 n1-run-ta NP-TA    # ticket A starts
mklock NP-TB n1-run-tb sess-2; pointer sess-2 n1-run-tb NP-TB    # ticket B overwrites the pointer
bind() { # <session> <ID>; prints "<restored>|<after n1_step_begin>|<n1_read_lock run>"
    env -i HOME="$HOME" PATH="$PATH" N1_ROOT="$ROOT" N1_HOME="$R/home" N1_SESSION_ID="$1" bash -c '
        source "$N1_ROOT/lib/preamble.sh" >/dev/null 2>&1; r0="${N1_RUN_ID:-}"; ID="$1"
        n1_step_begin ticket 1 >/dev/null 2>&1; lr=""
        n1_read_lock "$N1_HOME/memory" && lr="$N1_LOCK_RUN_ID"
        printf "%s|%s|%s" "$r0" "${N1_RUN_ID:-}" "$lr"' _ "$2"
}
test "$(bind sess-2 NP-TA)" = "n1-run-tb|n1-run-ta|n1-run-ta"   # restore picks B; bind re-resolves to A; read_lock agrees
test -s "$R/home/memory/NP-TA/telemetry/raw/steps/n1-run-ta.jsonl"
test ! -e "$R/home/memory/NP-TA/telemetry/raw/steps/n1-run-tb.jsonl"   # no orphan step file under A
test "$(bind sess-2 NP-TB)" = "n1-run-tb|n1-run-tb|n1-run-tb"   # matching ticket: unchanged
mklock NP-TC n1-run-tc sess-x                                     # C has no run in this session
test "$(bind sess-2 NP-TC)" = "n1-run-tb||"                       # dropped; ambiguous read_lock refuses
test ! -e "$R/home/memory/NP-TC/telemetry/raw"
mklock NP-TD n1-run-td1 sess-2; mklock NP-TD n1-run-td2 sess-2
test "$(bind sess-2 NP-TD)" = "n1-run-tb||"                       # several candidates: dropped
test ! -e "$R/home/memory/NP-TD/telemetry/raw"
LATE=$( ( N1_HOME="$R/home" N1_SESSION_ID=sess-2 N1_RUN_ID=n1-run-gone ID=NP-TA
          n1_bind_run_to_ticket; printf '%s' "${N1_RUN_ID:-}" ) )
test "$LATE" = n1-run-gone                                        # no lock anywhere (late event): fail-open
# SEC-1: a stray lock filename must not be adopted as a run id
mklock NP-TE n1-run-te sess-2
printf '{"session_id":"sess-2"}' > "$R/home/memory/NP-TE/telemetry/locks/foo bar.json"
test "$(bind sess-2 NP-TE)" = "n1-run-tb|n1-run-te|n1-run-te"
# CR-1: emitters given the stale run id write under the ticket's own run, never orphan
EM=$(N1_ROOT="$ROOT" N1_HOME="$R/home" N1_SESSION_ID=sess-2 bash -c 'source "$1/lib/preamble.sh" >/dev/null 2>&1
    n1_emit_outcome n1-run-tb v NP-TA "$2/memory/NP-TA/telemetry" a=b
    n1_emit_question_event n1-run-tb v NP-TA "$2/memory/NP-TA/telemetry" s design auto
    n1_emit_outcome n1-run-tb v NP-TC "$2/memory/NP-TC/telemetry" a=b' _ "$ROOT" "$R/home")
test "$(grep -c . "$R/home/memory/NP-TA/telemetry/raw/steps/n1-run-ta.jsonl")" -ge 3
test ! -e "$R/home/memory/NP-TA/telemetry/raw/steps/n1-run-tb.jsonl"
test ! -e "$R/home/memory/NP-TC/telemetry/raw"
# TQ-1: n1_record_decision also binds (n1_review_record not covered: needs a PR fixture)
(unset N1_RUN_ID N1_VERSION; export N1_ROOT="$ROOT" N1_HOME="$R/home" N1_SESSION_ID=sess-2; source "$ROOT/lib/preamble.sh" >/dev/null 2>&1; ID=NP-TA
  n1_record_decision d1 true >/dev/null 2>&1)
grep -q '"event":"decision"' "$R/home/memory/NP-TA/telemetry/raw/steps/n1-run-ta.jsonl"
echo 'PASS: bind run to ticket'

# Backstop: empty run id writes no .jsonl
mkdir -p "$R/tdir"
n1_emit_step_event "" v NP-R step 1 "$R/tdir" started_at=now
n1_emit_outcome "" v NP-R "$R/tdir" a=b
n1_emit_question_event "" v NP-R "$R/tdir" s design auto
test -z "$(find "$R/tdir" -type f 2>/dev/null)"
echo 'PASS: emitters drop events with empty run id'

# --- n1_close_run binds to the ticket (N1-193 CR-1) ---
export N1_SESSION_ID=thread-close N1_ROOT="$ROOT"
ID=CL-A; n1_run_begin "$ID"; CA="$N1_RUN_ID"
ID=CL-B; n1_run_begin "$ID"; CB="$N1_RUN_ID"
ID=CL-A; N1_RUN_ID="$CB"   # pointer/ambient overwritten by ticket B
FINAL_OUTCOME=pr_created ESTIMATED_TIER=simple n1_close_run
grep -q '"layer":"envelope_close"' "$N1_HOME/memory/CL-A/telemetry/raw/steps/$CA.jsonl"
if grep -q envelope_close "$N1_HOME/memory/CL-B/telemetry/raw/steps/$CB.jsonl"; then echo 'close landed in B' >&2; exit 1; fi
test ! -f "$N1_HOME/memory/CL-A/telemetry/locks/$CA.json"
test -f "$N1_HOME/memory/CL-B/telemetry/locks/$CB.json"
echo 'PASS: n1_close_run closes the ticket own run'
