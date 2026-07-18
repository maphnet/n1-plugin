#!/usr/bin/env bash
# N1 analysis cache helpers: snapshot I/O, freshness check, TTL parsing

n1_parse_ttl() {
    local ttl="$1"
    local num="${ttl%[hHmM]}"
    local unit="${ttl##*[0-9]}"
    case "$unit" in
        h|H) printf '%s' "$((num * 3600))" ;;
        m|M) printf '%s' "$((num * 60))" ;;
        *)   printf '%s' "$num" ;;
    esac
}

n1_snapshot_path() {
    local n1_home="$1"
    printf '%s' "${n1_home}/cache/project-snapshot.md"
}

n1_snapshot_write() {
    local snapshot_path="$1" project_content="$2" git_sha="$3"
    local cache_dir
    cache_dir=$(dirname "$snapshot_path")
    mkdir -p "$cache_dir"
    local git_sha_short="${git_sha:0:7}"
    local generated_at
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local file_count
    file_count=$(git ls-files 2>/dev/null | wc -l | tr -d ' ')
    local tmp
    tmp=$(mktemp "${cache_dir}/.project-snapshot.XXXXXX.tmp.md")
    {
        printf '%s\n' "---"
        printf 'schema_version: 1\n'
        printf 'generated_at: %s\n' "$generated_at"
        printf 'git_sha: %s\n' "$git_sha"
        printf 'git_sha_short: %s\n' "$git_sha_short"
        printf 'file_count: %s\n' "$file_count"
        printf 'generator: solution-architect\n'
        printf '%s\n' "---"
        printf '\n%s\n' "$project_content"
    } > "$tmp"
    mv "$tmp" "$snapshot_path"
}

n1_snapshot_read_body() {
    local snapshot_path="$1"
    [ -f "$snapshot_path" ] || return 1
    awk '
        NR==1 && /^---$/ { in_fm=1; next }
        in_fm && /^---$/ { in_fm=0; next }
        in_fm { next }
        { print }
    ' "$snapshot_path"
}

n1_snapshot_check_freshness() {
    local snapshot_path="$1" config_file="$2"

    # Cold: no snapshot exists
    if [ ! -f "$snapshot_path" ]; then
        printf 'cold'
        return 1
    fi

    source "$(dirname "${BASH_SOURCE[0]}")/frontmatter.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

    local git_sha generated_at
    git_sha=$(n1_read_frontmatter "$snapshot_path" "git_sha")
    generated_at=$(n1_read_frontmatter "$snapshot_path" "generated_at")

    # Stale: frontmatter missing or unparseable
    if [ -z "$git_sha" ] || [ -z "$generated_at" ]; then
        printf 'stale'
        return 1
    fi

    # Stale: git_sha no longer exists (force-push, rebase)
    if ! git rev-parse --verify "$git_sha" >/dev/null 2>&1; then
        printf 'stale'
        return 1
    fi

    # TTL check
    local ttl_str
    ttl_str=$(n1_config_val ".analysisCache.ttl" "$config_file")
    ttl_str="${ttl_str:-4h}"
    local ttl_seconds
    ttl_seconds=$(n1_parse_ttl "$ttl_str")
    local generated_epoch now_epoch
    generated_epoch=$(date -d "$generated_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$generated_at" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    if [ $((now_epoch - generated_epoch)) -gt "$ttl_seconds" ]; then
        printf 'stale'
        return 1
    fi

    # Git diff classification
    local diff_files
    diff_files=$(git diff --name-only "$git_sha"..HEAD 2>/dev/null)
    if [ $? -ne 0 ]; then
        printf 'stale'
        return 1
    fi

    # No changes at all → fresh
    if [ -z "$diff_files" ]; then
        printf 'fresh'
        return 0
    fi

    # Load structural file patterns from config (or defaults)
    local structural_raw
    structural_raw=$(n1_config_val ".analysisCache.structuralFiles" "$config_file")
    local structural_patterns
    if [ -z "$structural_raw" ]; then
        structural_patterns="package.json Cargo.toml go.mod pyproject.toml CLAUDE.md Dockerfile docker-compose.yml .github/workflows/*"
    elif [ "${structural_raw:0:1}" = "[" ]; then
        structural_patterns=$(echo "$structural_raw" | jq -r '.[]' 2>/dev/null)
    else
        structural_patterns="$structural_raw"
    fi

    local neutral_threshold
    neutral_threshold=$(n1_config_val ".analysisCache.neutralThreshold" "$config_file")
    neutral_threshold="${neutral_threshold:-15}"

    local structural_count=0 neutral_count=0
    while IFS= read -r changed_file; do
        [ -z "$changed_file" ] && continue

        # Check IGNORABLE first: test files, docs (non-CLAUDE.md), assets
        local basename="${changed_file##*/}"
        case "$changed_file" in
            test/*|tests/*|*_test.*|*.test.*|*.spec.*|__tests__/*) continue ;;
            *.md)
                if [ "$basename" != "CLAUDE.md" ]; then continue; fi
                ;;
            *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.woff|*.woff2|*.ttf|*.eot) continue ;;
        esac

        # Check STRUCTURAL
        local is_structural=0
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            case "$changed_file" in
                $pattern) is_structural=1; break ;;
            esac
        done <<< "$structural_patterns"

        if [ "$is_structural" -eq 1 ]; then
            structural_count=$((structural_count + 1))
        else
            neutral_count=$((neutral_count + 1))
        fi
    done <<< "$diff_files"

    # Any structural file changed → stale
    if [ "$structural_count" -gt 0 ]; then
        printf 'stale'
        return 1
    fi

    # Too many neutral files changed → stale
    if [ "$neutral_count" -gt "$neutral_threshold" ]; then
        printf 'stale'
        return 1
    fi

    printf 'fresh'
    return 0
}
