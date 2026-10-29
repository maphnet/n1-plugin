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
    printf '{"run_id":"%s","n1_version":"9.9.9","session_id":"%s"}\n' "$2" "$3" > "$R/home/memory/$1/telemetry/locks/$2.json"
}
pointer() { printf '{"ticketId":"X","runId":"%s","worktreePath":null,"branch":""}\n' "$2" > "$R/home/active-run.$1.json"; }
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

# Backstop: empty run id writes no .jsonl
mkdir -p "$R/tdir"
n1_emit_step_event "" v NP-R step 1 "$R/tdir" started_at=now
n1_emit_outcome "" v NP-R "$R/tdir" a=b
n1_emit_question_event "" v NP-R "$R/tdir" s design auto
test -z "$(find "$R/tdir" -type f 2>/dev/null)"
echo 'PASS: emitters drop events with empty run id'
