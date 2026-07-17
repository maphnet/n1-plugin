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

n1_read_type() {
    local overview_path="$1"
    local type_val
    source "${_N1_LIB_DIR}/frontmatter.sh"
    type_val=$(n1_read_frontmatter "$overview_path" "type")
    if [ -n "$type_val" ]; then
        printf '%s' "$type_val"
        return
    fi
    # Backward compat: fall back to "mode" if "type" is absent
    local mode_val
    mode_val=$(n1_read_frontmatter "$overview_path" "mode")
    if [ -n "$mode_val" ]; then
        printf '%s' "$mode_val"
    fi
}

n1_parse_type_arg() {
    local input="$1"
    case "$input" in
        *--type\ *)
            local type_name="${input##*--type }"
            type_name="${type_name%% *}"
            printf '%s' "$type_name"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

n1_resolve_type() {
    local title="$1" tags_csv="$2" type_field="$3" type_override="${4:-}"
    local pipeline_json="${CLAUDE_PLUGIN_ROOT}/pipeline.json"

    # 1. Explicit --type override: validate against registry
    if [ -n "$type_override" ]; then
        if jq -e --arg t "$type_override" '.types[$t]' "$pipeline_json" > /dev/null 2>&1; then
            printf '%s' "$type_override"
            return
        fi
        # Invalid override -- fall through to detection cascade
    fi

    local type_names
    type_names=$(jq -r '.types | keys[]' "$pipeline_json")

    # 2. Tag matching (alphabetical iteration)
    for tname in $type_names; do
        local has_tags
        has_tags=$(jq -r --arg t "$tname" '.types[$t].detect.tags // empty | length' "$pipeline_json")
        if [ -n "$has_tags" ] && [ "$has_tags" -gt 0 ] 2>/dev/null; then
            local detect_tags
            detect_tags=$(jq -r --arg t "$tname" '.types[$t].detect.tags[]' "$pipeline_json")
            for dtag in $detect_tags; do
                if echo "$tags_csv" | tr ',' '\n' | grep -qiE "^\s*${dtag}\s*$"; then
                    printf '%s' "$tname"
                    return
                fi
            done
        fi
    done

    # 3. type_field matching (alphabetical iteration)
    if [ -n "$type_field" ]; then
        for tname in $type_names; do
            local detect_tf
            detect_tf=$(jq -r --arg t "$tname" '.types[$t].detect.type_field // empty' "$pipeline_json")
            if [ -n "$detect_tf" ] && echo "$type_field" | grep -qiE "^${detect_tf}$"; then
                printf '%s' "$tname"
                return
            fi
        done
    fi

    # 4. title_match (alphabetical iteration)
    if [ -n "$title" ]; then
        for tname in $type_names; do
            local detect_tm
            detect_tm=$(jq -r --arg t "$tname" '.types[$t].detect.title_match // empty' "$pipeline_json")
            if [ -n "$detect_tm" ] && echo "$title" | grep -qi "$detect_tm"; then
                printf '%s' "$tname"
                return
            fi
        done
    fi

    # 5. Default type
    for tname in $type_names; do
        local is_default
        is_default=$(jq -r --arg t "$tname" '.types[$t].detect.default // false' "$pipeline_json")
        if [ "$is_default" = "true" ]; then
            printf '%s' "$tname"
            return
        fi
    done

    # Fallback if no default declared
    printf 'task'
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
