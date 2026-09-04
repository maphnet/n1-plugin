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

n1_extract_ticket_from_url() {
    local input="$1" config_file="$2"
    local prefix
    prefix=$(n1_config_val '.tracker.prefix' "$config_file")
    [ -z "$prefix" ] && return 1
    echo "$input" | grep -qE '^https?://' || return 1
    local ticket_id
    ticket_id=$(echo "$input" | grep -oE "${prefix}-[0-9]+" | head -1)
    [ -n "$ticket_id" ] && printf '%s' "$ticket_id" && return 0
    return 1
}

n1_detect_input_type() {
    local input="$1" config_file="$2"
    local prefix
    prefix=$(n1_config_val '.tracker.prefix' "$config_file")
    if [ -n "$prefix" ] && echo "$input" | grep -qE "^${prefix}-[0-9]+$"; then
        printf 'ticket'
        return
    fi
    local url_pattern=""
    if command -v jq >/dev/null 2>&1; then
        url_pattern=$(jq -r '[.observability.providers // {} | to_entries[] | .value.urlPattern // empty] | first // empty' "$config_file" 2>/dev/null)
    fi
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

# n1_title_hints_investigation <title> → 0 when the title reads like an investigation.
# Advisory only: titles never route (a false positive would skip implementation on real work).
n1_title_hints_investigation() {
    echo "$1" | grep -qiE '\b(investigation|investigate|spike|research)\b'
}

# Backward-compatible wrapper: tags only.
n1_detect_investigation() {
    local tags="$2"
    echo "$tags" | tr ',' '\n' | grep -qiE '^\s*investigation\s*$'
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
    N1_TYPE_MATCHED_BY=""

    # 1. Explicit --type override: validate against registry
    if [ -n "$type_override" ]; then
        if jq -e --arg t "$type_override" '.types[$t]' "$pipeline_json" > /dev/null 2>&1; then
            N1_TYPE_MATCHED_BY=override
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
                    N1_TYPE_MATCHED_BY=tags
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
                N1_TYPE_MATCHED_BY=type_field
                printf '%s' "$tname"
                return
            fi
        done
    fi

    # 4. Default type
    for tname in $type_names; do
        local is_default
        is_default=$(jq -r --arg t "$tname" '.types[$t].detect.default // false' "$pipeline_json")
        if [ "$is_default" = "true" ]; then
            N1_TYPE_MATCHED_BY=default
            printf '%s' "$tname"
            return
        fi
    done

    # Fallback if no default declared
    N1_TYPE_MATCHED_BY=default
    printf 'task'
}

