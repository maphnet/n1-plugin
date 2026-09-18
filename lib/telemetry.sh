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
        [ "$host" != unknown ] || host=$(n1_hook_field host < "$facts")
        [ -n "$transcript" ] || transcript=$(n1_hook_field transcript_path < "$facts")
    fi
    export N1_HOST="${host:-unknown}" N1_SESSION_ID="$session"
    N1_VERSION=$(n1_plugin_version)
    N1_RUN_ID="$(date -u +n1-run-%Y%m%dT%H%M%SZ)-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
    export N1_RUN_ID N1_VERSION
    python3 - "$tdir" "$N1_RUN_ID" "$N1_VERSION" "$ticket" "$N1_HOST" "$session" "$transcript" <<'PY'
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

n1_emit_step_event() {
    local run_id="$1" version="$2" ticket_id="$3" step="$4" step_number="$5" telem_dir="$6"
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
    shift 4
    local outcomes="{"
    local first=true
    for pair in "$@"; do
        local k="${pair%%=*}" v="${pair#*=}"
        $first || outcomes="${outcomes},"
        outcomes="${outcomes}\"${k}\":\"${v}\""
        first=false
    done
    outcomes="${outcomes}}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    local file="${tdir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$file")"
    printf '{"event":"outcome","run_id":"%s","n1_version":"%s","ticket_id":"%s","outcomes":%s,"timestamp":"%s"}\n' \
        "$run_id" "$version" "$ticket_id" "$outcomes" "$ts" >> "$file"
}

# n1_emit_compaction <run_id> <n1_version> <ticket_id> <telem_dir>
# Emits a compaction telemetry marker when context was compacted
n1_emit_compaction() {
    local run_id="$1" version="$2" ticket_id="$3" telem_dir="$4"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local file="${telem_dir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$file")"
    printf '{"event":"compaction","run_id":"%s","n1_version":"%s","ticket_id":"%s","timestamp":"%s"}\n' \
        "$run_id" "$version" "$ticket_id" "$ts" >> "$file"
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
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local file="${telem_dir}/raw/steps/${run_id}.jsonl"
    mkdir -p "$(dirname "$file")"
    printf '{"event":"question","run_id":"%s","n1_version":"%s","ticket_id":"%s","layer":"question","step":"%s","question_category":"%s","resolution":"%s","rungs_tried":"%s","timestamp":"%s"}\n' \
        "$(escape_json_val "$run_id")" "$(escape_json_val "$version")" "$(escape_json_val "$ticket_id")" \
        "$(escape_json_val "$step")" "$(escape_json_val "$category")" "$(escape_json_val "$resolution")" \
        "$(escape_json_val "$rungs")" "$ts" >> "$file"
}
