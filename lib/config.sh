#!/usr/bin/env bash
# N1 shared helpers: N1_HOME resolution, JSON config, model resolution, JSON escaping

n1_home() {
    local home
    home=$(git config n1.home 2>/dev/null || true)
    if [ -n "$home" ]; then
        home="${home/#\~/$HOME}"
        printf '%s' "$home"
        return
    fi
    if [ -f "${PWD}/.n1/n1.config.json" ]; then
        printf '%s' ".n1"
        return
    fi
    if [ -f "${PWD}/.n1/config.json" ]; then
        printf '%s' ".n1"
        return
    fi
}

n1_config_file() {
    local home
    home=$(n1_home)
    if [ -n "$home" ]; then
        if [ "${home#.}" != "$home" ] && [ -f "${PWD}/${home}/n1.config.json" ]; then
            printf '%s' "${home}/n1.config.json"
        else
            printf '%s' "${home}/config.json"
        fi
    else
        if [ -f "${PWD}/.n1/n1.config.json" ]; then
            printf '%s' ".n1/n1.config.json"
        elif [ -f "${PWD}/.n1/config.json" ]; then
            printf '%s' ".n1/config.json"
        fi
    fi
}

n1_config_val() {
    local path="$1" file="${2:-$(n1_config_file)}"
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r "${path} // empty" "$file" 2>/dev/null || true
        return
    fi
    local stripped="${path#.}"
    local section="${stripped%%.*}"
    local key="${stripped#*.}"
    # Value pattern matches quoted strings AND unquoted scalars (true/false/numbers/null),
    # so boolean gates like codex.enabled work without jq.
    local val_re="\"${key}\"[[:space:]]*:[[:space:]]*\(\"[^\"]*\"\|[-0-9a-zA-Z.]\{1,\}\)"
    if [ "$section" = "$key" ]; then
        grep -o "$val_re" "$file" 2>/dev/null \
            | head -1 | sed -e 's/.*:[[:space:]]*//' -e 's/^"//' -e 's/"$//' || true
    else
        awk -v sec="\"${section}\"" '
            $0 ~ sec { if ($0 ~ /:[[:space:]]*null/) exit; found=1; depth=0 }
            found && /{/ { depth++ }
            found && /}/ { depth--; if(depth<=0) { found=0 } }
            found { print }
        ' "$file" 2>/dev/null \
            | grep -o "$val_re" \
            | head -1 | sed -e 's/.*:[[:space:]]*//' -e 's/^"//' -e 's/"$//' || true
    fi
}

n1_config_ops() {
    local path="$1" file="${2:-$(n1_config_file)}"
    [ -f "$file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r "${path} // {} | to_entries | map(\"\(.key)=\(.value)\") | join(\", \")" "$file" 2>/dev/null || true
        return
    fi
    local stripped="${path#.}"
    local section="${stripped%%.*}"
    local opkey="${stripped#*.}"
    awk -v sec="\"${section}\"" '
        $0 ~ sec { found=1; depth=0 }
        found && /{/ { depth++ }
        found && /}/ { depth--; if(depth<=0) { found=0 } }
        found { print }
    ' "$file" 2>/dev/null \
        | awk -v ops="\"${opkey}\"" '
            $0 ~ ops { found=1; depth=0 }
            found && /{/ { depth++ }
            found && /}/ { depth--; if(depth<=0) { print; found=0; next } }
            found { print }
        ' 2>/dev/null \
        | grep -o '"[a-zA-Z_]*"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | grep -v "\"${opkey}\"" \
        | sed 's/"\([^"]*\)"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1=\2/' \
        | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g' || true
}

n1_resolve_tier() {
    local tier="$1" base_model="$2"
    case "$tier" in
        frontier) printf 'opus' ;;
        standard) printf '%s' "$base_model" ;;
        downgrade)
            case "$base_model" in
                opus) printf 'sonnet' ;;
                sonnet) printf 'haiku' ;;
                *) printf '%s' "$base_model" ;;
            esac
            ;;
        minimal) printf 'haiku' ;;
        *) printf '%s' "$base_model" ;;
    esac
}

n1_resolve_model() {
    local agent_name="$1"
    local context="${2:-}"
    local override=""
    local config_file
    config_file=$(n1_config_file)

    # 1. Config override (always wins)
    if [ -f "$config_file" ]; then
        if command -v jq >/dev/null 2>&1; then
            override=$(jq -r ".models[\"${agent_name}\"] // empty" "$config_file" 2>/dev/null || true)
        else
            override=$(n1_config_val ".models.${agent_name}" "$config_file")
        fi
    fi
    if [ -n "$override" ]; then
        printf '%s' "$override"
        return
    fi

    # Get base model from agent frontmatter
    local base_model=""
    local agent_file="${CLAUDE_PLUGIN_ROOT}/agents/${agent_name}.md"
    if [ -f "$agent_file" ]; then
        base_model=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm && /^model:/ { sub(/^model:[[:space:]]*/, ""); gsub(/\r/, ""); printf "%s", $0; exit }' "$agent_file")
    fi
    base_model="${base_model:-sonnet}"

    # 2. Signal-driven escalation/downgrade
    local pipeline_file="${CLAUDE_PLUGIN_ROOT}/pipeline.json"
    if [ -f "$pipeline_file" ] && [ -n "$context" ]; then
        local trigger_key="${agent_name}:${context}"
        local trigger_tier=""
        if command -v jq >/dev/null 2>&1; then
            trigger_tier=$(jq -r ".downgrade_triggers[\"${trigger_key}\"].tier // empty" "$pipeline_file" 2>/dev/null || true)
        fi
        if [ -n "$trigger_tier" ]; then
            n1_resolve_tier "$trigger_tier" "$base_model"
            return
        fi
    fi

    # 3. Profile step_overrides (from type registry)
    if [ -f "$pipeline_file" ] && [ -n "$N1_HOME" ] && [ -n "$ID" ]; then
        local overview_file="${N1_HOME}/memory/${ID}/overview.md"
        if [ -f "$overview_file" ]; then
            source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh" 2>/dev/null || true
            local wf_type
            wf_type=$(n1_read_frontmatter "$overview_file" "type" 2>/dev/null || true)
            if [ -n "$wf_type" ]; then
                local step_name="$context"
                [ -z "$step_name" ] && step_name="$agent_name"
                local profile_tier=""
                if command -v jq >/dev/null 2>&1; then
                    profile_tier=$(jq -r ".types[\"${wf_type}\"].step_overrides[\"${step_name}\"].model_tier // empty" "$pipeline_file" 2>/dev/null || true)
                fi
                if [ -n "$profile_tier" ]; then
                    n1_resolve_tier "$profile_tier" "$base_model"
                    return
                fi
            fi
        fi
    fi

    # 4. Agent frontmatter default
    printf '%s' "$base_model"
}

n1_codex_companion() {
    local newest=""
    local newest_ver=""
    local f
    local ver
    for f in "${HOME}"/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs; do
        [ -f "$f" ] || continue
        ver="${f%/scripts/codex-companion.mjs}"   # strip trailing /scripts/codex-companion.mjs
        ver="${ver##*/}"                          # keep the <version> dir name
        if [ -z "$newest" ] || [ "$(printf '%s\n%s\n' "$newest_ver" "$ver" | sort -V | tail -1)" = "$ver" ]; then
            newest="$f"
            newest_ver="$ver"
        fi
    done
    printf '%s' "$newest"
}

n1_codex_val() {
    local key="$1"
    local val
    val=$(n1_config_val ".codex.${key}")
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return
    fi
    n1_config_val ".codexReview.${key}"
}

n1_codex_available() {
    local enabled
    enabled=$(n1_codex_val 'enabled')
    [ "$enabled" = "true" ] || return 1
    CODEX=$(n1_codex_companion)
    [ -n "$CODEX" ] || return 1
    codex --version >/dev/null 2>&1 || return 1
    return 0
}

n1_codex_preflight() {
    local base_branch="$1"
    n1_codex_available || return 1
    if ! git rev-parse --verify "$base_branch" >/dev/null 2>&1; then
        echo "base branch '$base_branch' not resolvable" >&2
        return 1
    fi
    return 0
}

escape_json_val() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
