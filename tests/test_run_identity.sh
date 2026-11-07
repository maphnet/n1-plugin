#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
LIVE=""
trap 'kill $LIVE 2>/dev/null || true; rm -rf "$T"' EXIT
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
# Close merges but keeps the lock: the turn's Stop hook re-merges the tail (Gate 3, chained
# n1-finish) and removes it (N1-229; removal covered by test_hooks.sh terminal-pointer case).
test -s "$N1_HOME/memory/CL-A/telemetry/runs/$CA.jsonl"
test -f "$N1_HOME/memory/CL-A/telemetry/locks/$CA.json"
test -f "$N1_HOME/memory/CL-B/telemetry/locks/$CB.json"
echo 'PASS: n1_close_run closes the ticket own run'

# N1-434: close without FINAL_OUTCOME/ESTIMATED_TIER in env derives them from overview.md
ID=CL-D; n1_run_begin "$ID"; CD="$N1_RUN_ID"
printf -- '---\ntier: standard\n---\n# CL-D\n\n## Pending\nawaiting: merge\npr: 123\n' > "$N1_HOME/memory/CL-D/overview.md"
(unset FINAL_OUTCOME ESTIMATED_TIER; n1_close_run)
for f in steps runs; do
    L=$(grep envelope_close "$N1_HOME/memory/CL-D/telemetry/raw/steps/$CD.jsonl" | tail -1)
    [ "$f" = steps ] || L=$(grep -h '"final_outcome"' "$N1_HOME/memory/CL-D/telemetry/runs/$CD.jsonl" | tail -1)
    case "$L" in *'"final_outcome": "pr_created"'*|*'"final_outcome":"pr_created"'*) ;; *) echo "FAIL: n1_close_run derives outcome and tier from overview.md, env wins ($f: outcome not derived: $L)" >&2; exit 1 ;; esac
    case "$L" in *'"estimated_tier": "standard"'*|*'"estimated_tier":"standard"'*) ;; *) echo "FAIL: n1_close_run derives outcome and tier from overview.md, env wins ($f: tier not derived: $L)" >&2; exit 1 ;; esac
done
(unset ESTIMATED_TIER; FINAL_OUTCOME=escalated n1_close_run)
grep envelope_close "$N1_HOME/memory/CL-D/telemetry/raw/steps/$CD.jsonl" | tail -1 | grep -q '"final_outcome":"escalated"' || { echo "FAIL: n1_close_run derives outcome and tier from overview.md, env wins (env outcome not kept)" >&2; exit 1; }
echo 'PASS: n1_close_run derives outcome and tier from overview.md, env wins'

# N1-482: frontmatter pr_url and a ## Finish pr_url also derive pr_created; other sections do not
ID=CL-F; n1_run_begin "$ID"; CF="$N1_RUN_ID"
printf -- '---\ntier: simple\npr_url: https://example.test/pr/7\n---\n# CL-F\n' > "$N1_HOME/memory/CL-F/overview.md"
(unset FINAL_OUTCOME ESTIMATED_TIER; n1_close_run)
grep envelope_close "$N1_HOME/memory/CL-F/telemetry/raw/steps/$CF.jsonl" | tail -1 | grep -q '"final_outcome":"pr_created"' || { echo "FAIL: n1_close_run derives pr_created from frontmatter pr_url" >&2; exit 1; }
ID=CL-G; n1_run_begin "$ID"; CG="$N1_RUN_ID"
printf -- '---\ntier: simple\n---\n# CL-G\n\n## Finish\nmerged: true\npr_url: https://example.test/pr/8\n' > "$N1_HOME/memory/CL-G/overview.md"
(unset FINAL_OUTCOME ESTIMATED_TIER; n1_close_run)
grep envelope_close "$N1_HOME/memory/CL-G/telemetry/raw/steps/$CG.jsonl" | tail -1 | grep -q '"final_outcome":"pr_created"' || { echo "FAIL: n1_close_run derives pr_created from ## Finish pr_url" >&2; exit 1; }
ID=CL-H; n1_run_begin "$ID"; CH="$N1_RUN_ID"
printf -- '---\ntier: simple\npr_url: ""\n---\n# CL-H\n\n## Notes\npr: 9\n' > "$N1_HOME/memory/CL-H/overview.md"
(unset FINAL_OUTCOME ESTIMATED_TIER; n1_close_run)
grep envelope_close "$N1_HOME/memory/CL-H/telemetry/raw/steps/$CH.jsonl" | tail -1 | grep -q '"final_outcome":""' || { echo "FAIL: n1_close_run ignores empty pr_url and pr lines outside Pending/Finish" >&2; exit 1; }
echo 'PASS: n1_close_run derives pr_created from frontmatter and ## Finish pr_url'

# N1-434 SEC-1: quotes/backslashes in overview values still yield valid JSON
ID=CL-E; n1_run_begin "$ID"; CE="$N1_RUN_ID"
printf -- '---\ntier: "standard\\x"\n---\n# CL-E\n' > "$N1_HOME/memory/CL-E/overview.md"
(unset FINAL_OUTCOME ESTIMATED_TIER; n1_close_run)
L=$(grep envelope_close "$N1_HOME/memory/CL-E/telemetry/raw/steps/$CE.jsonl" | tail -1)
if ! jq -e '.layer == "envelope_close"' <<< "$L" >/dev/null 2>&1; then echo "FAIL: n1_close_run escapes overview values in envelope_close (invalid JSON: $L)" >&2; exit 1; fi
echo 'PASS: n1_close_run escapes overview values in envelope_close'

# N1-479: close with ID unset derives the ticket from the bound run's lock; unresolvable run writes nothing
ID=CL-F; n1_run_begin "$ID"; CF="$N1_RUN_ID"
unset ID
FINAL_OUTCOME=pr_created ESTIMATED_TIER=simple n1_close_run
test -s "$N1_HOME/memory/CL-F/telemetry/runs/$CF.jsonl"
grep -q '"layer":"envelope_close"' "$N1_HOME/memory/CL-F/telemetry/raw/steps/$CF.jsonl"
test -z "${ID:-}"   # derived ticket does not leak to the caller
test ! -e "$N1_HOME/memory/telemetry" && test ! -e "$N1_HOME/memory//telemetry"
N1_RUN_ID=n1-run-nolock-0001 FINAL_OUTCOME=pr_created n1_close_run
test ! -e "$N1_HOME/memory/telemetry"
test -z "$(find "$N1_HOME/memory" -path '*nolock*' 2>/dev/null)"
echo 'PASS: n1_close_run with ID unset derives the ticket from the run lock, no-op when unresolvable'

# n1_step_begin with no bound run says so on stderr instead of dropping silently (N1-229)
ERR=$(bash -c "source '$ROOT/lib/preamble.sh' >/dev/null 2>&1; unset N1_RUN_ID; ID=NP-NONE; n1_step_begin ticket 1" 2>&1 >/dev/null)
case "$ERR" in *"no run bound for NP-NONE"*) ;; *) echo "missing step-begin diagnostic: $ERR" >&2; exit 1 ;; esac
echo 'PASS: unbound step begin is reported on stderr'

# --- n1_merge_pending recovers runs whose session ended without finalize (N1-486) ---
# Live owner: a process whose cmdline contains "claude" (test_owner_guard.sh pattern); dead pid: unused pid.
AB="$T/abandon/home"; mkdir -p "$AB/memory"
SLEEP_BIN=$(readlink -f "$(command -v sleep)")
ln -s "$(command -v sleep)" "$T/claude"
"$T/claude" 60 & LIVE=$!
if [ -r "/proc/$$/cmdline" ]; then
    for _ in $(seq 50); do [ "$(readlink "/proc/$LIVE/exe" 2>/dev/null)" = "$SLEEP_BIN" ] && break; sleep 0.1; done
fi
DEAD=99999; while kill -0 "$DEAD" 2>/dev/null; do DEAD=$((DEAD-1)); done
abrun() { # <ticket> <run> <session> <pid|-|none> <aged 1|0>   "-" = pointer without pid, none = no pointer
    local td="$AB/memory/$1/telemetry"
    mkdir -p "$td/locks" "$td/raw/steps" "$td/raw/agents" "$td/runs"
    printf '{"run_id":"%s","n1_version":"9.9.9","ticket_id":"%s","host":"claude-code","session_id":"%s"}\n' "$2" "$1" "$3" > "$td/locks/$2.json"
    cp "$td/locks/$2.json" "$td/telemetry.lock"
    printf '{"layer":"envelope","run_id":"%s","session_id":"%s","started_at":"2026-01-01T00:00:00Z"}\n' "$2" "$3" > "$td/raw/steps/$2.jsonl"
    case "$4" in
        none) ;;
        -) printf '{"ticketId":"%s","runId":"%s","worktreePath":null,"branch":""}\n' "$1" "$2" > "$AB/active-run.$3.json" ;;
        *) printf '{"ticketId":"%s","runId":"%s","worktreePath":null,"branch":"","pid":%s}\n' "$1" "$2" "$4" > "$AB/active-run.$3.json" ;;
    esac
    [ "$5" = 0 ] || touch -d '2 days ago' "$td/raw/steps/$2.jsonl" "$td/locks/$2.json"
}
abrun AB-DEAD n1-run-abdead s-dead "$DEAD" 1
printf -- '---\ntype: bug\ntier: standard\n---\n' > "$AB/memory/AB-DEAD/overview.md"
echo '{"run_id":"n1-run-abdead","layer":"agent","event":"start","agent_id":"a1","agent_type":"developer"}' \
    > "$AB/memory/AB-DEAD/telemetry/raw/agents/n1-run-abdead.jsonl"     # unmatched agent start must not block
abrun AB-LIVE n1-run-ablive s-live "$LIVE" 1        # AC2: live owner, however old
abrun AB-FRESH n1-run-abfresh s-fresh - 0           # pid-less pointer, active within 24h
abrun AB-LEGACY n1-run-ablegacy s-legacy - 1        # pid-less pointer, idle: age decides
abrun AB-NOPTR n1-run-abnoptr s-noptr none 1        # pointer cleared (handoff), idle
abrun AB-SELF n1-run-abself s-self none 1           # the current session's own lock
( export N1_HOME="$AB" N1_SESSION_ID=s-self; unset N1_RUN_ID; n1_merge_pending "$AB/memory" )
abandoned() { # <ticket> <run>: merged as abandoned, both locks gone
    grep -Eq '"final_outcome": ?"abandoned"' "$AB/memory/$1/telemetry/runs/$2.jsonl" 2>/dev/null \
        && [ ! -e "$AB/memory/$1/telemetry/locks/$2.json" ] && [ ! -e "$AB/memory/$1/telemetry/telemetry.lock" ]
}
untouched() { # <ticket> <run>: lock kept, nothing merged, no close written
    [ -f "$AB/memory/$1/telemetry/locks/$2.json" ] && [ ! -e "$AB/memory/$1/telemetry/runs/$2.jsonl" ] \
        && ! grep -q envelope_close "$AB/memory/$1/telemetry/raw/steps/$2.jsonl"
}
for c in AB-DEAD:n1-run-abdead AB-LEGACY:n1-run-ablegacy AB-NOPTR:n1-run-abnoptr; do
    abandoned "${c%%:*}" "${c#*:}" || { echo "FAIL: $c not merged as abandoned" >&2; exit 1; }
done
grep envelope_close "$AB/memory/AB-DEAD/telemetry/raw/steps/n1-run-abdead.jsonl" \
    | jq -e '.final_outcome == "abandoned" and .type == "bug" and .estimated_tier == "standard" and .ticket_id == "AB-DEAD"' >/dev/null \
    || { echo 'FAIL: abandoned envelope lacks overview type/tier' >&2; exit 1; }
for c in AB-LIVE:n1-run-ablive AB-FRESH:n1-run-abfresh AB-SELF:n1-run-abself; do
    untouched "${c%%:*}" "${c#*:}" || { echo "FAIL: $c was merged" >&2; exit 1; }
done
# Without jq the pointer's unquoted pid must still protect a live owner.
NOJQ="$T/nojq-bin"; mkdir -p "$NOJQ"
for d in /usr/bin /bin; do for f in "$d"/*; do [ "${f##*/}" = jq ] || ln -sf "$f" "$NOJQ/${f##*/}" 2>/dev/null || true; done; done
abrun AB-NOJQ n1-run-abnojq s-nojq "$LIVE" 1
( export N1_HOME="$AB" N1_SESSION_ID=s-self PATH="$NOJQ"; unset N1_RUN_ID; ! command -v jq >/dev/null && n1_merge_pending "$AB/memory" )
untouched AB-NOJQ n1-run-abnojq || { echo 'FAIL: live owner not protected without jq' >&2; exit 1; }
kill "$LIVE" 2>/dev/null || true
echo 'PASS: n1_merge_pending abandons dead idle runs and keeps live, fresh and own runs'
