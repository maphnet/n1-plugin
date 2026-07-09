#!/usr/bin/env bash
# N1 validation helpers: dependency checks, input type detection

_N1_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_N1_LIB_DIR}/config.sh"

n1_verify_dependencies() {
    local memory_dir="$1"; shift
    local missing=()
    for f in "$@"; do
        local path="${memory_dir}/${f}"
        if [ ! -f "$path" ] || [ ! -s "$path" ]; then
            missing+=("$f")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        printf 'Missing or empty dependency files: %s\n' "${missing[*]}" >&2
        return 1
    fi
    return 0
}

n1_detect_input_type() {
    local input="$1" config_file="$2"
    local prefix
    prefix=$(n1_config_val '.tracker.prefix' "$config_file")
    if [ -n "$prefix" ] && echo "$input" | grep -qE "^${prefix}-[0-9]+$"; then
        printf 'ticket'
        return
    fi
    local url_pattern
    url_pattern=$(n1_config_val '.errorTracking.urlPattern' "$config_file")
    if [ -n "$url_pattern" ] && echo "$input" | grep -qE "$url_pattern"; then
        printf 'error-tracker'
        return
    fi
    if [ -f "$input" ]; then
        printf 'file'
        return
    fi
    printf 'braindump'
}

n1_detect_investigation() {
    local title="$1" tags="$2"
    # Case-insensitive word boundary match for "investigation" or "investigate" in title
    if echo "$title" | grep -qiE '\b(investigation|investigate)\b'; then
        return 0
    fi
    # Case-insensitive exact match for "investigation" tag
    if echo "$tags" | tr ',' '\n' | grep -qiE '^\s*investigation\s*$'; then
        return 0
    fi
    return 1
}

N1_VALID_STEPS="ticket analysis brainstorm plan plan-review estimation implementation qa review fix local-testing pr ci finish investigation-deliverable"

n1_parse_step_arg() {
    local input="$1"
    case "$input" in
        *--step\ *)
            local step_name="${input##*--step }"
            step_name="${step_name%% *}"
            local id_part="${input%%--step*}"
            id_part="${id_part%% }"
            id_part="${id_part% }"
            for valid in $N1_VALID_STEPS; do
                if [ "$step_name" = "$valid" ]; then
                    printf 'step=%s id=%s' "$step_name" "$id_part"
                    return 0
                fi
            done
            printf 'Invalid step name '\''%s'\''. Valid steps: %s\n' "$step_name" "$N1_VALID_STEPS" >&2
            return 2
            ;;
        *)
            return 1
            ;;
    esac
}

n1_emit_step_result() {
    local step="$1" outcome="$2" next_step="$3" loop_counter="${4:-null}"
    local extra="${5:-}"
    local next_json
    if [ "$next_step" = "null" ]; then
        next_json="null"
    else
        next_json="\"$next_step\""
    fi
    printf 'N1_STEP_RESULT: {"step":"%s","outcome":"%s","next_step":%s,"loop_counter":%s%s}\n' \
        "$step" "$outcome" "$next_json" "$loop_counter" "$extra"
    if [ -n "${N1_HOME:-}" ] && [ -n "${ID:-}" ]; then
        local result_file="${N1_HOME}/memory/${ID}/step-result.json"
        printf '{"step":"%s","outcome":"%s","next_step":%s,"loop_counter":%s}\n' \
            "$step" "$outcome" "$next_json" "$loop_counter" \
            > "${result_file}.tmp" && mv "${result_file}.tmp" "${result_file}" || true
    fi
}

n1_step_dependencies() {
    local step="$1"
    case "$step" in
        ticket)          printf '' ;;
        analysis)        printf 'ticket.md' ;;
        brainstorm)      printf 'ticket.md analysis.md' ;;
        plan)            printf 'ticket.md brainstorm.md analysis.md' ;;
        plan-review)     printf 'ticket.md analysis.md brainstorm.md plan.md' ;;
        estimation)      printf 'ticket.md analysis.md brainstorm.md' ;;
        implementation)  printf 'brainstorm.md' ;;
        qa)              printf 'ticket.md implementation.md plan.md' ;;
        review)          printf 'ticket.md brainstorm.md implementation.md qa.md' ;;
        fix)             printf 'implementation.md' ;;
        local-testing)   printf 'implementation.md' ;;
        pr)              printf 'overview.md review.md qa.md implementation.md' ;;
        ci)              printf 'overview.md plan.md implementation.md' ;;
        finish)          printf 'overview.md' ;;
        investigation-deliverable) printf 'ticket.md analysis.md' ;;
        *)               return 1 ;;
    esac
}

n1_step_number() {
    local step="$1"
    case "$step" in
        ticket)          printf '1' ;;
        analysis)        printf '2' ;;
        brainstorm)      printf '3' ;;
        plan)            printf '4' ;;
        plan-review)     printf '5' ;;
        estimation)      printf '6' ;;
        implementation)  printf '7' ;;
        qa)              printf '8' ;;
        review)          printf '9' ;;
        fix)             printf '10' ;;
        local-testing)   printf '11' ;;
        pr)              printf '12' ;;
        ci)              printf '13' ;;
        finish)          printf '14' ;;
        investigation-deliverable) printf '15' ;;
        *)               return 1 ;;
    esac
}
