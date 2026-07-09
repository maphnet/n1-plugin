#!/usr/bin/env bash
# N1 telemetry helpers: step event emission, lock file reading

_N1_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_N1_LIB_DIR}/config.sh"

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
    local lock_file
    lock_file=$(ls -t "${memory_dir}"/*/telemetry/telemetry.lock 2>/dev/null | head -1) || true
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

    N1_LOCK_TELEM_DIR=$(dirname "$lock_file")
    N1_LOCK_TICKET_ID=$(basename "$(dirname "$N1_LOCK_TELEM_DIR")")
}

n1_merge_pending() {
    local memory_dir="$1"
    n1_read_lock "$memory_dir" || return 0

    local merged_file="${N1_LOCK_TELEM_DIR}/runs/${N1_LOCK_RUN_ID}.jsonl"
    local saved_run_id="$N1_LOCK_RUN_ID"
    local lock_file="${N1_LOCK_TELEM_DIR}/telemetry.lock"

    if [ ! -s "$merged_file" ]; then
        local merge_script
        merge_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../hooks/telemetry-merge.sh"
        bash "$merge_script" "$N1_LOCK_RUN_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true
    fi

    # Remove lock only if merged output exists and lock still belongs to the stale run
    if [ -s "$merged_file" ] && [ -f "$lock_file" ]; then
        local current_run_id
        current_run_id=$(grep -o '"run_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$lock_file" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"/\1/' || true)
        [ "$current_run_id" = "$saved_run_id" ] && rm -f "$lock_file"
    fi
}
