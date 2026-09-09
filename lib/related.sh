#!/usr/bin/env bash
# N1 cross-repo awareness helpers: project map I/O, related project resolution,
# diff-based detection, config append.

_n1_related_lib_dir="$(dirname "${BASH_SOURCE[0]}")"
source "${_n1_related_lib_dir}/frontmatter.sh"
source "${_n1_related_lib_dir}/cache.sh"
source "${_n1_related_lib_dir}/config.sh"

# Escape ERE metacharacters so a slug/service name is matched literally.
n1_related_escape_ere() {
    printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

n1_project_map_path() {
    local n1_home="$1"
    printf '%s' "${n1_home}/cache/project-map.md"
}

n1_related_project_map() {
    local slug="$1"
    printf '%s' "${HOME}/.n1/${slug}/cache/project-map.md"
}

n1_project_map_check_freshness() {
    local map_path="$1" max_age="$2"

    if [ ! -f "$map_path" ]; then
        printf 'cold'
        return 1
    fi

    local generated_at
    generated_at=$(n1_read_frontmatter "$map_path" "generated_at")

    if [ -z "$generated_at" ]; then
        printf 'stale'
        return 1
    fi

    local max_seconds
    max_seconds=$(n1_parse_ttl "$max_age")
    local generated_epoch now_epoch
    generated_epoch=$(date -d "$generated_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$generated_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)

    if [ $((now_epoch - generated_epoch)) -gt "$max_seconds" ]; then
        printf 'stale'
        return 1
    fi

    printf 'fresh'
    return 0
}

n1_related_projects() {
    local config_file="$1"
    [ -f "$config_file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local enabled
    enabled=$(jq -r '.relatedProjects.enabled // false' "$config_file" 2>/dev/null)
    [ "$enabled" = "true" ] || return 0

    jq -r '.relatedProjects.projects // [] | .[] | .slug' "$config_file" 2>/dev/null | while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        local peer_config="${HOME}/.n1/${slug}/config.json"
        [ -f "$peer_config" ] || continue
        local repo_path
        repo_path=$(jq -r '.repoPath // empty' "$peer_config" 2>/dev/null)
        [ -n "$repo_path" ] || continue
        local reason
        reason=$(jq -r --arg s "$slug" '.relatedProjects.projects[] | select(.slug == $s) | .reason // ""' "$config_file" 2>/dev/null)
        printf '%s\t%s\t%s\n' "$slug" "$reason" "$repo_path"
    done
}

# n1_related_detect_in_diff <diff_text> <config_file> [current_slug]
# Reports N1 projects referenced in the diff that are not yet registered.
# The current project is always excluded — a repo is never its own related
# project. When <current_slug> is omitted it is derived from n1_home().
n1_related_detect_in_diff() {
    local diff_text="$1" config_file="$2" current_slug="${3:-}"
    command -v jq >/dev/null 2>&1 || return 0

    if [ -z "$current_slug" ]; then
        current_slug=$(basename "$(n1_home)")
    fi

    # Collect known slugs already in relatedProjects
    local known_slugs
    known_slugs=$(jq -r '.relatedProjects.projects // [] | .[].slug' "$config_file" 2>/dev/null)

    # Scan all N1 projects for service names and slugs
    local cfg slug service
    for cfg in "${HOME}"/.n1/*/config.json; do
        [ -f "$cfg" ] || continue
        slug=$(basename "$(dirname "$cfg")")
        # Never suggest the current project as its own related project
        [ "$slug" = "$current_slug" ] && continue
        # Skip if already known
        if [ -n "$known_slugs" ] && printf '%s\n' "$known_slugs" | grep -qxF "$slug"; then
            continue
        fi
        service=$(jq -r '.ticketTagging.service // empty' "$cfg" 2>/dev/null)
        local repo_path
        repo_path=$(jq -r '.repoPath // empty' "$cfg" 2>/dev/null)
        [ -n "$repo_path" ] || continue

        # Check the diff for references to this project's slug or service name.
        # Case-insensitive, metacharacters escaped, non-alphanumeric boundaries
        # on both sides so short slugs (api, web) do not match everything.
        local names
        names=$(n1_related_escape_ere "$slug")
        [ -n "$service" ] && names="${names}|$(n1_related_escape_ere "$service")"
        local pattern="(^|[^a-zA-Z0-9])(${names})([^a-zA-Z0-9]|\$)"
        if printf '%s\n' "$diff_text" | grep -iqE "$pattern"; then
            local signal
            signal=$(printf '%s\n' "$diff_text" | grep -iE "$pattern" | head -1 \
                | sed 's/^[+-]//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            printf '%s\t%s\n' "$slug" "$signal"
        fi
    done
}

n1_related_add() {
    local config_file="$1" slug="$2" reason="$3" source="$4"
    command -v jq >/dev/null 2>&1 || return 0

    # Idempotent: skip if slug already present
    local existing
    existing=$(jq -r --arg s "$slug" '.relatedProjects.projects // [] | .[] | select(.slug == $s) | .slug' "$config_file" 2>/dev/null)
    [ -z "$existing" ] || return 0

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    jq --arg s "$slug" --arg r "$reason" --arg src "$source" --arg t "$ts" \
        '.relatedProjects.projects += [{"slug": $s, "reason": $r, "source": $src, "confirmedAt": $t}]' \
        "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
}
