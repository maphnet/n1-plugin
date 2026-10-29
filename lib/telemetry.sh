#!/usr/bin/env bash
# N1 telemetry helpers: step event emission, lock file reading

_N1_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_N1_LIB_DIR}/config.sh"

# Capture immutable routing identity before any pipeline work. The compatibility
# lock is only a pointer; hooks select the per-run lock by session identity.
n1_run_begin() {
    local ticket="$1" tdir host session facts transcript
    tdir="${N1_HOME}/memory/$ticket/telemetry"
    host=$(n1_host); session=$(n1_session_id)
    facts=$(n1_session_file 2>/dev/null || true)
    transcript="${N1_TRANSCRIPT_PATH:-}"
    if [ -f "$facts" ]; then
        [ -n "$transcript" ] || transcript=$(n1_hook_field transcript_path < "$facts")
    fi
    export N1_SESSION_ID="$session"
    N1_VERSION=$(n1_plugin_version)
    N1_RUN_ID="$(date -u +n1-run-%Y%m%dT%H%M%SZ)-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
    export N1_RUN_ID N1_VERSION
    python3 - "$tdir" "$N1_RUN_ID" "$N1_VERSION" "$ticket" "$host" "$session" "$transcript" <<'PY'
import json, os, pathlib, sys
from datetime import datetime, timezone
tdir = pathlib.Path(sys.argv[1])
run, version, ticket, host, session, transcript = sys.argv[2:]
for sub in ('raw/steps', 'raw/agents', 'runs', 'locks'):
    (tdir / sub).mkdir(parents=True, exist_ok=True)
identity = dict(run_id=run, n1_version=version, ticket_id=ticket,
                host=host, session_id=session or None,
                session_transcript_path=transcript or None)
identity['parent_session_id'] = os.environ.get('N1_PARENT_SESSION_ID') or None
payload = json.dumps(identity) + '\n'
(tdir / 'locks' / (run + '.json')).write_text(payload)
(tdir / 'telemetry.lock').write_text(payload)
identity.update(layer='envelope', started_at=datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
(tdir / 'raw/steps' / (run + '.jsonl')).write_text(json.dumps(identity) + '\n')
PY
}

# Each Bash call is a fresh shell, so N1_RUN_ID/N1_VERSION set by n1_run_begin are gone in later
# snippets. Restore them (plain assignment, NOT exported) from this session's keyed active-run
# pointer + live lock. Fail-open: always returns 0, leaves vars unset on any mismatch.
# Ticket agreement is checked at use time: see n1_bind_run_to_ticket.
# Single allowlist for any run id taken from a pointer or a lock filename (N1-193).
_n1_valid_run_id() { case "$1" in n1-run-*[!A-Za-z0-9._-]*|n1-run-) return 1 ;; n1-run-*) return 0 ;; *) return 1 ;; esac; }

n1_restore_run_identity() {
    [ -z "${N1_RUN_ID:-}" ] || return 0
    local sid f run lock
    sid=$(n1_session_id); [ -n "$sid" ] || return 0
    f=$(n1_active_run_file 2>/dev/null) || return 0
    case "$f" in */active-run."$sid".json) ;; *) return 0 ;; esac
    [ -f "$f" ] || return 0
    run=$(n1_hook_field runId < "$f")
    _n1_valid_run_id "$run" || return 0
    for lock in "${N1_HOME:-$(n1_home)}"/memory/*/telemetry/locks/"$run".json; do
        [ -f "$lock" ] || continue
        [ "$(n1_hook_field session_id < "$lock")" = "$sid" ] || continue
        N1_RUN_ID="$run"
        N1_VERSION=$(n1_hook_field n1_version < "$lock")
        case "$N1_VERSION" in *[!0-9A-Za-z.+-]*) N1_VERSION="" ;; esac
        return 0
    done
    return 0
}

# Run/ticket agreement, documented once here (N1-193). The restored N1_RUN_ID comes from the
# session's active-run pointer, which the session's latest n1_run_begin overwrites; a second
# ticket in one session would make an earlier ticket's snippets write under the wrong run.
# ID-aware writers call this first. Ground truth is the lock path memory/$ID/telemetry/locks/<run>.json
# (it follows reconcile renames; the pointer's ticketId does not):
#   - run's lock under $ID: agree.
#   - run's lock only under another ticket (pointer overwritten): re-resolve to the one run this
#     session owns under $ID; none or several -> unset N1_RUN_ID/N1_VERSION so writers no-op.
#   - run has no lock anywhere (FINALIZE removed it; late events): unchanged (fail-open).
# n1_read_lock's ambient N1_RUN_ID filter then selects the same run. Hooks have no ambient id and
# no ID and keep their session/ambiguity rules. Plain vars, never exported; always returns 0.
n1_bind_run_to_ticket() {
    [ -n "${N1_RUN_ID:-}" ] && [ -n "${ID:-}" ] || return 0
    local mem="${N1_HOME:-$(n1_home)}/memory" sid lock="" run="" cand="" n=0
    [ ! -f "$mem/$ID/telemetry/locks/$N1_RUN_ID.json" ] || return 0
    for lock in "$mem"/*/telemetry/locks/"$N1_RUN_ID".json; do
        [ -f "$lock" ] && break
    done
    [ -f "$lock" ] || return 0
    sid=$(n1_session_id)
    for lock in "$mem/$ID"/telemetry/locks/*.json; do
        [ -f "$lock" ] && [ -n "$sid" ] || continue
        [ "$(n1_hook_field session_id < "$lock")" = "$sid" ] || continue
        cand="${lock##*/}"; cand="${cand%.json}"
        _n1_valid_run_id "$cand" || continue
        run="$cand"; n=$((n + 1))
    done
    unset N1_RUN_ID N1_VERSION
    [ "$n" = 1 ] || return 0
    N1_RUN_ID="$run"
    N1_VERSION=$(n1_hook_field n1_version < "$mem/$ID/telemetry/locks/$run.json")
    case "$N1_VERSION" in *[!0-9A-Za-z.+-]*) N1_VERSION="" ;; esac
    return 0
}

n1_emit_step_event() {
    local run_id="$1" version="$2" ticket_id="$3" step="$4" step_number="$5" telem_dir="$6"
    [ -n "$run_id" ] || return 0
    shift 6

    local started_at="" completed_at="" outcome="" loop_iteration="" metadata="{}"
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        [ "$v" = "now" ] && v=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        case "$k" in
            started_at) started_at="$v" ;;
            completed_at) completed_at="$v" ;;
            outcome) outcome="$v" ;;
            loop_iteration) loop_iteration="$v" ;;
            metadata) metadata="$v" ;;
        esac
    done

    local outfile="${telem_dir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$outfile")"

    local json="{\"run_id\":\"$(escape_json_val "$run_id")\",\"n1_version\":\"$(escape_json_val "$version")\",\"ticket_id\":\"$(escape_json_val "$ticket_id")\",\"layer\":\"step\",\"step\":\"$(escape_json_val "$step")\",\"step_number\":${step_number}"
    [ -n "$started_at" ] && json="${json},\"started_at\":\"${started_at}\""
    [ -n "$completed_at" ] && json="${json},\"completed_at\":\"${completed_at}\""
    [ -n "$outcome" ] && json="${json},\"outcome\":\"$(escape_json_val "$outcome")\""
    [ -n "$loop_iteration" ] && json="${json},\"loop_iteration\":${loop_iteration}"
    [ "$metadata" != "{}" ] && json="${json},\"metadata\":${metadata}"
    json="${json}}"

    echo "$json" >> "$outfile"
}

# n1_emit_rebind <run_id> <ticket_id>: prints "<run>\t<version>" after the ticket agreement check
# (empty run = drop the write). Subshell: caller's N1_RUN_ID/ID/N1_VERSION stay untouched.
n1_emit_rebind() {
    ( N1_RUN_ID="$1"; ID="$2"; N1_VERSION=""; n1_bind_run_to_ticket
      printf '%s\t%s' "${N1_RUN_ID:-}" "${N1_VERSION:-}" )
}

# n1_close_run: FINALIZE close for $ID (needs FINAL_OUTCOME, ESTIMATED_TIER): bind run to ticket, write
# envelope_close, merge, drop the lock. Unbound run (no/ambiguous) -> no-op. Always returns 0.
n1_close_run() {
    n1_bind_run_to_ticket
    [ -n "${N1_RUN_ID:-}" ] || return 0
    local tdir="${N1_HOME}/memory/$ID/telemetry" t
    t=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "type" 2>/dev/null || true)
    echo '{"layer":"envelope_close","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","completed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","final_outcome":"'"${FINAL_OUTCOME:-}"'","estimated_tier":"'"${ESTIMATED_TIER:-}"'","type":"'"$t"'"}' >> "$tdir/raw/steps/$N1_RUN_ID.jsonl"
    bash "$N1_ROOT/hooks/telemetry-merge.sh" "$N1_RUN_ID" "$tdir" 2>&1 || echo "⚠ Telemetry merge failed" >&2
    [ -s "$tdir/runs/$N1_RUN_ID.jsonl" ] && n1_remove_run_lock "$tdir" "$N1_RUN_ID"
    return 0
}

n1_read_lock() {
    local memory_dir="$1"
    local lock_file="" candidate session owner run host selected_run=""
    session=$(n1_session_id); host=$(n1_host)
    # Identity-less hooks must not guess another session's most recent run.
    [ -n "$session" ] || [ -n "${N1_RUN_ID:-}" ] || return 1
    for candidate in "${memory_dir}"/*/telemetry/locks/*.json "${memory_dir}"/*/telemetry/telemetry.lock; do
        [ -f "$candidate" ] || continue
        owner=$(n1_hook_field session_id < "$candidate")
        run=$(n1_hook_field run_id < "$candidate")
        # In-snippet callers have the ambient id ticket-checked first (n1_bind_run_to_ticket).
        [ -z "${N1_RUN_ID:-}" ] || [ "$run" = "$N1_RUN_ID" ] || continue
        [ -z "$session" ] || [ "$owner" = "$session" ] || continue
        [ "$(n1_hook_field host < "$candidate")" = "$host" ] || continue
        # Multiple unfinished pipelines in one thread are ambiguous to a hook.
        # Require an explicit run ID rather than attributing to the newest one.
        [ -z "$selected_run" ] || [ "$selected_run" = "$run" ] || return 1
        selected_run="$run"
        lock_file="$candidate"
    done
    [ -n "$lock_file" ] || return 1

    local lock_content
    lock_content=$(cat "$lock_file")

    if command -v jq >/dev/null 2>&1; then
        N1_LOCK_RUN_ID=$(echo "$lock_content" | jq -r '.run_id // empty' 2>/dev/null || true)
        N1_LOCK_VERSION=$(echo "$lock_content" | jq -r '.n1_version // empty' 2>/dev/null || true)
    else
        N1_LOCK_RUN_ID=$(echo "$lock_content" | grep -o '"run_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
        N1_LOCK_VERSION=$(echo "$lock_content" | grep -o '"n1_version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
    fi
    [ -n "$N1_LOCK_RUN_ID" ] || return 1

    N1_LOCK_FILE="$lock_file"
    N1_LOCK_TELEM_DIR=$(dirname "$lock_file")
    [ "$(basename "$N1_LOCK_TELEM_DIR")" != locks ] || N1_LOCK_TELEM_DIR=$(dirname "$N1_LOCK_TELEM_DIR")
    N1_LOCK_TICKET_ID=$(basename "$(dirname "$N1_LOCK_TELEM_DIR")")
}

# n1_run_has_pending_agent <agents_file>
# True if a background agent's "start" event has no matching "stop" event yet —
# i.e. the run is paused waiting on it, not abandoned. Missing/empty file => false.
n1_run_has_pending_agent() {
    local agents_file="$1"
    [ -s "$agents_file" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        local pending
        pending=$(jq -s -r '
            group_by(.agent_id) |
            any(.[]; (map(select(.event == "start")) | length) > 0
                and (map(select(.event == "stop")) | length) == 0)
        ' "$agents_file" 2>/dev/null || echo false)
        [ "$pending" = "true" ]
    else
        local started stopped id
        started=$(grep '"event"[[:space:]]*:[[:space:]]*"start"' "$agents_file" 2>/dev/null | \
            grep -o '"agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
        stopped=$(grep '"event"[[:space:]]*:[[:space:]]*"stop"' "$agents_file" 2>/dev/null | \
            grep -o '"agent_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
        for id in $started; do
            printf '%s\n' "$stopped" | grep -qxF "$id" || return 0
        done
        return 1
    fi
}

n1_remove_run_lock() {
    local tdir="$1" run="$2" pointer="$1/telemetry.lock"
    case "$run" in ''|*[!a-zA-Z0-9_-]*) return 1;; esac
    rm -f "$tdir/locks/$run.json"
    if [ -f "$pointer" ] && [ "$(n1_hook_field run_id < "$pointer")" = "$run" ]; then
        rm -f "$pointer"
    fi
}

# n1_emit_outcome <run_id> <n1_version> <ticket_id> <telemetry_dir> [key=value ...]
# Appends a pipeline-completion quality outcome event
# Expected keys: review_pass_first_try, qa_pass_first_try, fix_cycles_count, total_duration_s
n1_emit_outcome() {
    local run_id="$1" version="$2" ticket_id="$3" tdir="$4"
    [ -n "$run_id" ] || return 0
    local rb; rb=$(n1_emit_rebind "$run_id" "$ticket_id")
    [ -n "${rb%%$'\t'*}" ] || return 0
    [ "${rb%%$'\t'*}" = "$run_id" ] || { run_id="${rb%%$'\t'*}"; version="${rb#*$'\t'}"; }
    shift 4
    local outcomes="{"
    local first=true
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        $first || outcomes="${outcomes},"
        outcomes="${outcomes}\"$(escape_json_val "$k")\":\"$(escape_json_val "$v")\""
        first=false
    done
    outcomes="${outcomes}}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    local file="${tdir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$file")"
    printf '{"event":"outcome","run_id":"%s","n1_version":"%s","ticket_id":"%s","outcomes":%s,"timestamp":"%s"}\n' \
        "$(escape_json_val "$run_id")" "$(escape_json_val "$version")" "$(escape_json_val "$ticket_id")" "$outcomes" "$ts" >> "$file"
}

n1_merge_pending() {
    local memory_dir="$1"
    n1_read_lock "$memory_dir" || return 0

    local merged_file="${N1_LOCK_TELEM_DIR}/runs/${N1_LOCK_RUN_ID}.jsonl"
    local saved_run_id="$N1_LOCK_RUN_ID"

    if [ ! -s "$merged_file" ]; then
        local merge_script
        merge_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../hooks/telemetry-merge.sh"
        bash "$merge_script" "$N1_LOCK_RUN_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true
    fi

    # Remove lock only if merged output exists and lock still belongs to the stale run
    [ ! -s "$merged_file" ] || n1_remove_run_lock "$N1_LOCK_TELEM_DIR" "$saved_run_id"
}

# n1_record_decision <decision_id> <result:true|false> [<condition_json>] [key=value ...]
# Appends a decision event paired with the signal values it read. No-op without a telemetry lock.
n1_record_decision() {
    local id="$1" result="$2" cond="${3:-}"
    shift 2; [ $# -gt 0 ] && shift
    [ -n "${N1_HOME:-}" ] && [ -n "${ID:-}" ] || return 0
    n1_bind_run_to_ticket
    local tdir="${N1_HOME}/memory/${ID}/telemetry"
    n1_read_lock "${N1_HOME}/memory" || return 0
    [ "$N1_LOCK_TICKET_ID" = "$ID" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local run_id version
    run_id="$N1_LOCK_RUN_ID"
    version="$N1_LOCK_VERSION"

    type n1_read_signal >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/signals.sh"
    local signals="{}" mem_dir="${N1_HOME}/memory/${ID}"
    if [ -n "$cond" ]; then
        local sig prefix key val
        for sig in $(echo "$cond" | jq -r '.. | .signal? // empty' 2>/dev/null | sort -u); do
            prefix="${sig%%.*}"; key="${sig#*.}"
            val=$(n1_read_signal "${mem_dir}/${prefix}.md" "$key" 2>/dev/null || true)
            signals=$(echo "$signals" | jq -c --arg k "$sig" --arg v "$val" '. + {($k): $v}')
        done
    fi
    local kv
    for kv in "$@"; do
        signals=$(echo "$signals" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}')
    done
    [ -n "$cond" ] || cond="null"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "${tdir}/raw/steps"
    jq -cn --arg run "$run_id" --arg ver "$version" --arg tid "$ID" --arg id "$id" --argjson res "$result" \
        --argjson cond "$cond" --argjson sig "$signals" --arg ts "$ts" \
        '{event:"decision",run_id:$run,n1_version:$ver,ticket_id:$tid,id:$id,result:$res,condition:$cond,signals:$sig,timestamp:$ts}' \
        >> "${tdir}/raw/steps/${run_id}.jsonl"
    return 0
}

# n1_emit_question_event <run_id> <n1_version> <ticket_id> <telem_dir> <step> <question_category> <resolution> [rungs_tried]
# Emits a question-layer telemetry event. resolution: asked|auto|auto-decided|decide-for-me|inherited
# question_category: design|mechanical|quality|scope
n1_emit_question_event() {
    local run_id="$1" version="$2" ticket_id="$3" telem_dir="$4" step="$5"
    local category="$6" resolution="$7" rungs="${8:-}"
    [ -n "$run_id" ] || return 0
    local rb; rb=$(n1_emit_rebind "$run_id" "$ticket_id")
    [ -n "${rb%%$'\t'*}" ] || return 0
    [ "${rb%%$'\t'*}" = "$run_id" ] || { run_id="${rb%%$'\t'*}"; version="${rb#*$'\t'}"; }
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local file="${telem_dir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$file")"
    printf '{"event":"question","run_id":"%s","n1_version":"%s","ticket_id":"%s","layer":"question","step":"%s","question_category":"%s","resolution":"%s","rungs_tried":"%s","timestamp":"%s"}\n' \
        "$(escape_json_val "$run_id")" "$(escape_json_val "$version")" "$(escape_json_val "$ticket_id")" \
        "$(escape_json_val "$step")" "$(escape_json_val "$category")" "$(escape_json_val "$resolution")" \
        "$(escape_json_val "$rungs")" "$ts" >> "$file"
}
