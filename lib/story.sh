#!/usr/bin/env bash
# N1 story orchestrator helpers (n1-story-run). Pure functions; no MCP calls.
# Requires lib/config.sh sourced first (n1_config_val, escape_json_val).

n1_story_parse_service() {
    # Usage: n1_story_parse_service <title>
    # Prints the service tag from "<service> | <title>" or nothing.
    local title="$1"
    case "$title" in
        *" |"*) printf '%s' "${title%% |*}" | sed 's/[[:space:]]*$//' ;;
        *) printf '' ;;
    esac
}

n1_story_find_repo() {
    # Usage: n1_story_find_repo <service> [n1_root]
    # Prints "<config-path>\t<repoPath>" for the first ~/.n1/*/config.json whose
    # ticketTagging.service matches case-insensitively. Exit 1 when none match.
    local service="$1" root="${2:-$HOME/.n1}"
    local want; want=$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')
    local cfg svc repo
    for cfg in "$root"/*/config.json; do
        [ -f "$cfg" ] || continue
        svc=$(jq -r '.ticketTagging.service // empty' "$cfg" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -n "$svc" ] && [ "$svc" = "$want" ] || continue
        repo=$(jq -r '.repoPath // empty' "$cfg" 2>/dev/null)
        printf '%s\t%s' "$cfg" "$repo"
        return 0
    done
    return 1
}

n1_story_val() {
    # Usage: n1_story_val <key> — .story.<key> from config, else defaults/story.json.
    local key="$1" val
    val=$(n1_config_val ".story.${key}")
    if [ -z "$val" ]; then
        val=$(n1_config_val ".${key}" "${CLAUDE_PLUGIN_ROOT}/defaults/story.json")
    fi
    printf '%s' "$val"
}

_n1_story_size_rank() {
    case "$1" in
        XS) echo 1 ;; S) echo 2 ;; M) echo 3 ;; L) echo 4 ;; XL) echo 5 ;;
        *) echo 2 ;;  # unknown/empty counts as S
    esac
}

n1_story_pick_model() {
    # Usage: n1_story_pick_model <size> [flags-csv]
    # sonnet by default; opus when size >= story.opusFromSize or a risk flag is set.
    local size="$1" flags="${2:-}" threshold
    threshold=$(n1_story_val opusFromSize)
    local f
    local -a _flags
    IFS=',' read -r -a _flags <<< "$flags"
    for f in "${_flags[@]:-}"; do
        case "$f" in
            security|public-api|schema-migration|contract) printf 'opus'; return ;;
        esac
    done
    if [ "$(_n1_story_size_rank "$size")" -ge "$(_n1_story_size_rank "${threshold:-M}")" ]; then
        printf 'opus'
    else
        printf 'sonnet'
    fi
}
