#!/usr/bin/env bash
# N1 shared helpers: N1_HOME resolution, JSON config, model resolution, JSON escaping
# shellcheck source=host.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/host.sh"

n1_home() {
    local home

    # 1. Env-var override (highest priority — platform-local, user-controlled)
    if [ -n "${N1_HOME:-}" ]; then
        printf '%s' "$N1_HOME"
        return
    fi

    # 2. Auto-derive from repo name: $HOME/.n1/<slug>
    # Try both remote-URL and directory-name slugs — n1-init historically used
    # directory name, so existing setups may only match that.
    local slug_remote slug_dir candidate
    slug_remote=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null || true)
    slug_dir=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
    for candidate in "$slug_remote" "$slug_dir"; do
        [ -n "$candidate" ] || continue
        candidate=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
        home="${HOME}/.n1/${candidate}"
        if [ -d "$home" ]; then
            printf '%s' "$home"
            return
        fi
    done

    # 3. Legacy: git config n1.home (backward compat)
    home=$(git config n1.home 2>/dev/null || true)
    if [ -n "$home" ]; then
        home="${home/#\~/$HOME}"
        if [ -n "${WSL_DISTRO_NAME:-}" ] && [[ "$home" =~ ^[A-Z]:/ ]]; then
            home=$(wslpath -u "$home" 2>/dev/null) || true
        fi
        printf '%s' "$home"
        return
    fi

    # 4. Legacy: in-repo .n1/
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
        jq -r "if (${path}) == null then empty else (${path}) end" "$file" 2>/dev/null || true
        return
    fi
    local stripped="${path#.}"
    local section="${stripped%%.*}"
    local key="${stripped#*.}"
    # Value pattern matches quoted strings AND unquoted scalars (true/false/numbers/null),
    # so boolean gates like estimation.enabled work without jq.
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

n1_codex_default() {
    # Usage: n1_codex_default <key> — value of [agents].<key> in the Codex CLI config.toml
    local f="${CODEX_HOME:-$HOME/.codex}/config.toml"
    [ -f "$f" ] || return 0
    awk -v key="$1" '
        /^[[:space:]]*\[/ { sec=$0; gsub(/[[:space:]]/, "", sec) }
        sec=="[agents]" && $1==key { if (match($0, /"[^"]*"/)) print substr($0, RSTART+1, RLENGTH-2); exit }
    ' "$f"
}

_n1_agent_frontmatter() {
    # Usage: _n1_agent_frontmatter <persona> <model|effort>
    local persona="$1" key="$2" agent_file
    agent_file="$(n1_plugin_root)/agents/${persona}.md"
    [ -f "$agent_file" ] || return 0
    awk -v key="$key" 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm && $0 ~ "^" key ":[[:space:]]*" { sub("^" key ":[[:space:]]*", ""); gsub(/\r/, ""); print; exit }' "$agent_file"
}

n1_translate_model() {
    # Usage: n1_translate_model <host> <neutral opus|sonnet|haiku role>
    local host="$1" role="$2" pipeline_file value=""
    pipeline_file="$(n1_plugin_root)/pipeline.json"
    if [ -f "$pipeline_file" ] && command -v jq >/dev/null 2>&1; then
        value=$(jq -r --arg h "$host" --arg r "$role" '.model_policy.host_mappings[$h][$r] // empty' "$pipeline_file" 2>/dev/null || true)
    fi
    [ -n "$value" ] && { printf '%s' "$value"; return; }
    case "$host:$role" in
        claude-code:opus|claude-code:sonnet|claude-code:haiku) printf '%s' "$role" ;;
        codex:opus) printf 'gpt-5.6-sol' ;;
        codex:sonnet) printf 'gpt-5.6-terra' ;;
        codex:haiku) printf 'gpt-5.6-luna' ;;
        *) printf '%s' "$role" ;;
    esac
}

_n1_known_role() {
    local role
    role=$(_n1_agent_frontmatter "$1" model)
    case "$role" in opus|sonnet|haiku) printf '%s' "$role";; esac
}

_n1_astra_eligible() {
    local context="${1:-}" minimum="2" pipeline_file overview cycle
    case "$context" in
        final-whole-branch-review|architecture-adjudication) return 0 ;;
        failed-fix-escalation) ;;
        *) return 1 ;;
    esac
    pipeline_file="$(n1_plugin_root)/pipeline.json"
    if [ -f "$pipeline_file" ] && command -v jq >/dev/null 2>&1; then
        minimum=$(jq -r '.model_policy.exceptional_models["gpt-6-astra"].eligible_contexts["failed-fix-escalation"].minimum // 2' "$pipeline_file" 2>/dev/null || printf 2)
    fi
    overview="${N1_HOME:-}/memory/${ID:-}/overview.md"
    [ -f "$overview" ] || return 1
    type n1_read_frontmatter >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/frontmatter.sh" 2>/dev/null || true
    cycle=$(n1_read_frontmatter "$overview" review_fix_cycle 2>/dev/null || true)
    [[ "$cycle" =~ ^[0-9]+$ ]] && [[ "$minimum" =~ ^[0-9]+$ ]] && [ "$cycle" -ge "$minimum" ]
}

_n1_warn_ineligible_astra() {
    local persona="$1" context="${2:-none}"
    [ -n "$context" ] || context=none
    printf "N1: ineligible gpt-6-astra override for %s in context '%s'; using normal tier policy.\n" "$persona" "$context" >&2
}

_n1_model_override() {
    # Usage: _n1_model_override <persona> — models.<persona> from config for the current host, or empty.
    # String = legacy Claude-only value; object = {"claude-code": m, "codex": m | {"model": m, "reasoning_effort": e}}.
    local persona="$1" host config_file
    host=$(n1_host); config_file=$(n1_config_file)
    [ -f "$config_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$persona" --arg h "$host" '
            .models[$p] as $e |
            if ($e|type) == "string" then (if $h == "claude-code" then $e else empty end)
            elif ($e|type) == "object" then ($e[$h] | if type == "object" then (.model // empty) else (. // empty) end)
            else empty end' "$config_file" 2>/dev/null || true
    elif [ "$host" = "claude-code" ]; then
        n1_config_val ".models.${persona}" "$config_file"
    fi
}

n1_model_for() {
    # Usage: n1_model_for <persona> — the model to spawn this persona with on the current host.
    local persona="$1" v role
    role=$(_n1_known_role "$persona")
    if [ -n "$role" ]; then n1_resolve_model "$persona"; return; fi
    v=$(_n1_model_override "$persona")
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    if [ "$(n1_host)" = "codex" ]; then n1_codex_default default_subagent_model; return; fi
    printf 'sonnet'
}

_n1_clamp_codex_effort() {
    local persona="$1" requested="${2:-}" order="low medium high xhigh max ultra" minimum="medium" pipeline_file
    pipeline_file="$(n1_plugin_root)/pipeline.json"
    if [ -f "$pipeline_file" ] && command -v jq >/dev/null 2>&1; then
        order=$(jq -r '.model_policy.codex_effort.order // ["low","medium","high","xhigh","max","ultra"] | join(" ")' "$pipeline_file" 2>/dev/null || printf '%s' "$order")
        minimum=$(jq -r '.model_policy.codex_effort.minimum // "medium"' "$pipeline_file" 2>/dev/null || printf '%s' "$minimum")
    fi
    [ -n "$requested" ] || { printf '%s' "$minimum"; return; }
    if [ "$requested" = "low" ]; then
        printf "N1: Codex effort 'low' for %s is below policy floor '%s'; using %s.\n" "$persona" "$minimum" "$minimum" >&2
        printf '%s' "$minimum"; return
    fi
    case " $order " in *" $requested "*) printf '%s' "$requested";; *) printf "N1: unsupported Codex effort '%s' for %s; using %s.\n" "$requested" "$persona" "$minimum" >&2; printf '%s' "$minimum";; esac
}

n1_reasoning_effort_for() {
    # Usage: n1_reasoning_effort_for <persona> — Codex reasoning effort for a spawn; empty on Claude Code.
    [ "$(n1_host)" = "codex" ] || return 0
    local persona="$1" config_file v=""
    config_file=$(n1_config_file)
    if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
        v=$(jq -r --arg p "$persona" '.models[$p].codex.reasoning_effort? // empty' "$config_file" 2>/dev/null || true)
    fi
    [ -n "$v" ] || v=$(n1_codex_default default_subagent_reasoning_effort)
    [ -n "$v" ] || v=$(_n1_agent_frontmatter "$persona" effort)
    _n1_clamp_codex_effort "$persona" "$v"
}

n1_resolve_model() {
    local agent_name="$1"
    local context="${2:-}"
    local astra_context="${3:-}"
    local override=""
    local config_file
    config_file=$(n1_config_file)

    # 1. Config override (always wins); host-keyed objects resolve to the current host's value
    override=$(_n1_model_override "$agent_name")
    if [ -n "$override" ]; then
        if [ "$(n1_host)" != "codex" ] || [ "$override" != "gpt-6-astra" ]; then printf '%s' "$override"; return; fi
        if _n1_astra_eligible "$astra_context"; then printf '%s' "$override"; return; fi
        _n1_warn_ineligible_astra "$agent_name" "$astra_context"
    fi

    # Get base model from agent frontmatter
    local base_model host
    host=$(n1_host)
    base_model=$(_n1_known_role "$agent_name")
    if [ -z "$base_model" ]; then
        if [ "$host" = "codex" ]; then n1_codex_default default_subagent_model; else printf 'sonnet'; fi
        return
    fi

    # 2. Signal-driven escalation/downgrade (condition-gated)
    local pipeline_file="$(n1_plugin_root)/pipeline.json"
    if [ -f "$pipeline_file" ] && [ -n "$context" ] && command -v jq >/dev/null 2>&1; then
        local trigger_key="${agent_name}:${context}"
        local mem_dir="${N1_HOME:+${N1_HOME}/memory/${ID}}"
        local overview_file="${mem_dir:+${mem_dir}/overview.md}"

        type n1_eval_signal_gate >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/signals.sh" 2>/dev/null || true

        local section trigger_tier trigger_cond
        for section in escalation_triggers downgrade_triggers; do
            trigger_tier=$(jq -r ".${section}[\"${trigger_key}\"].tier // empty" "$pipeline_file" 2>/dev/null || true)
            [ -n "$trigger_tier" ] || continue

            trigger_cond=$(jq -c ".${section}[\"${trigger_key}\"].condition // empty" "$pipeline_file" 2>/dev/null || true)
            if [ -z "$trigger_cond" ] || [ "$trigger_cond" = '""' ]; then
                # No condition — apply unconditionally
                n1_translate_model "$host" "$(n1_resolve_tier "$trigger_tier" "$base_model")"
                return
            fi

            # Evaluate condition; requires memory dir
            if [ -n "$mem_dir" ] && [ -d "$mem_dir" ]; then
                type n1_record_decision >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/telemetry.sh" 2>/dev/null || true
                local dec_id="${section%_triggers}:${trigger_key}"   # e.g. escalation:developer:implementation
                if n1_eval_signal_gate "$mem_dir" "$overview_file" "$trigger_cond"; then
                    n1_record_decision "$dec_id" true "$trigger_cond" "tier=${trigger_tier}" 2>/dev/null || true
                    n1_translate_model "$host" "$(n1_resolve_tier "$trigger_tier" "$base_model")"
                    return
                else
                    n1_record_decision "$dec_id" false "$trigger_cond" "tier=${trigger_tier}" 2>/dev/null || true
                fi
            fi
        done
    fi

    # 3. Profile step_overrides (from type registry)
    if [ -f "$pipeline_file" ] && [ -n "$N1_HOME" ] && [ -n "$ID" ]; then
        local overview_file="${N1_HOME}/memory/${ID}/overview.md"
        if [ -f "$overview_file" ]; then
            source "$(n1_plugin_root)/lib/frontmatter.sh" 2>/dev/null || true
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
                    n1_translate_model "$host" "$(n1_resolve_tier "$profile_tier" "$base_model")"
                    return
                fi
            fi
        fi
    fi

    # 4. Agent frontmatter default
    n1_translate_model "$host" "$base_model"
}

n1_resolve_agent() {
    local persona="$1" step_context="${2:-}" astra_context="${3:-}"
    [ "$(n1_host)" != unknown ] || { echo 'N1: unknown host; cannot resolve dispatch configuration' >&2; return 1; }
    local model effort
    model=$(n1_resolve_model "$persona" "$step_context" "$astra_context")
    effort=$(n1_reasoning_effort_for "$persona")
    printf '%s\t%s\n' "$model" "$effort"
}


n1_autonomy_val() {
    # Usage: n1_autonomy_val <key>
    # Reads autonomy.mode from config and derives the sub-key value.
    # Falls back to legacy individual key when autonomy.mode is absent.
    # Unset config -> hands-off defaults (convention over configuration).
    local key="$1"

    # Env override: N1_AUTONOMY_PRESET=autonomous -> hands-off values
    if [ "${N1_AUTONOMY_PRESET:-}" = "autonomous" ]; then
        case "$key" in
            brainstorm)         printf 'auto';        return ;;
            mechanicalPrompts)  printf 'auto';        return ;;
            qualityEscalations) printf 'auto-accept'; return ;;
            tailChain)          printf 'suggest';     return ;;
            acceptanceGate)     printf 'auto';        return ;;
            escalationMargin)   printf '0.05';        return ;;
        esac
    fi

    # Read the consolidated mode key
    local mode
    mode=$(n1_config_val '.autonomy.mode')

    if [ -n "$mode" ]; then
        # New-style config: derive sub-key from mode
        case "$mode" in
            hands-off)
                case "$key" in
                    brainstorm)         printf 'auto';        return ;;
                    mechanicalPrompts)  printf 'auto';        return ;;
                    qualityEscalations) printf 'auto-accept'; return ;;
                    tailChain)          printf 'suggest';     return ;;
                    acceptanceGate)     printf 'auto';        return ;;
                    escalationMargin)   printf '0.05';        return ;;
                esac
                ;;
            interactive)
                case "$key" in
                    brainstorm)         printf 'interactive'; return ;;
                    mechanicalPrompts)  printf 'ask';         return ;;
                    qualityEscalations) printf 'block';       return ;;
                    tailChain)          printf 'suggest';     return ;;
                    acceptanceGate)     printf 'ask';         return ;;
                    escalationMargin)   printf '0.15';        return ;;
                esac
                ;;
        esac
    fi

    # Legacy fallback: autonomy.mode absent -> read individual key
    local val
    val=$(n1_config_val ".autonomy.${key}")
    if [ -n "$val" ]; then
        printf '%s' "$val"
        return
    fi

    # Unset config -> hands-off defaults
    case "$key" in
        brainstorm)         printf 'auto' ;;
        mechanicalPrompts)  printf 'auto' ;;
        qualityEscalations) printf 'auto-accept' ;;
        tailChain)          printf 'suggest' ;;
        acceptanceGate)     printf 'auto' ;;
        escalationMargin)   printf '0.05' ;;
        *)                  printf '' ;;
    esac
}

n1_emit_autonomy_deprecation_note() {
    # Prints a one-line deprecation note if the config contains individual
    # autonomy sub-keys but no autonomy.mode key.
    # Returns 0 if a note was printed, 1 if not.
    local config_file="${1:-$(n1_config_file)}"
    [ -f "$config_file" ] || return 1
    # Check for autonomy.mode presence
    local mode
    mode=$(n1_config_val '.autonomy.mode' "$config_file")
    [ -n "$mode" ] && return 1  # New-style config — no note needed
    # Check for any legacy autonomy sub-keys
    local has_legacy
    has_legacy=$(n1_config_val '.autonomy.brainstorm' "$config_file")
    [ -z "$has_legacy" ] && has_legacy=$(n1_config_val '.autonomy.mechanicalPrompts' "$config_file")
    [ -n "$has_legacy" ] || return 1
    printf 'N1: autonomy config uses legacy keys (brainstorm, mechanicalPrompts, …). They still work — add "autonomy": {"mode": "hands-off"} to silence this note.\n'
    return 0
}

n1_plan_approval_required() {
    # Prints true/false. The autonomous env preset always disables the plan checkpoint.
    if [ "${N1_AUTONOMY_PRESET:-}" = "autonomous" ]; then printf 'false'; return; fi
    local v; v=$(n1_config_val '.planReview.requirePlanApproval')
    [ "$v" = "true" ] && printf 'true' || printf 'false'
}

n1_plan_review_enabled() {
    # Prints true/false. Default: true (plan review always runs unless explicitly disabled).
    # Cannot use n1_config_val here: jq's `// empty` treats boolean false as falsy,
    # returning empty string for both absent AND false. Use null-check instead.
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r 'if .planReview.reviewPlan == null then "absent" else (.planReview.reviewPlan | tostring) end' "$file" 2>/dev/null || true)
        [ "$v" = "false" ] && { printf 'false'; return; }
        [ "$v" = "true" ] && { printf 'true'; return; }
    fi
    printf 'true'
}

n1_test_coverage_tier() {
    # Prints maintain/minimal/standard. Default: maintain.
    local v; v=$(n1_config_val '.testCoverage.tier')
    printf '%s' "${v:-maintain}"
}

n1_review_min_clean_passes() {
    # Prints integer. Default: 1.
    local v; v=$(n1_config_val '.review.minCleanPasses')
    printf '%s' "${v:-1}"
}

n1_review_narrow_threshold() {
    # Prints integer. Default: 50.
    local v; v=$(n1_config_val '.review.narrowThreshold')
    printf '%s' "${v:-50}"
}

n1_review_skip_doc_config() {
    # Prints true/false. Default: true.
    # Cannot use n1_config_val here: jq's `// empty` treats boolean false as falsy.
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r 'if .review.skipDocConfigOnly == null then "absent" else (.review.skipDocConfigOnly | tostring) end' "$file" 2>/dev/null || true)
        [ "$v" = "false" ] && { printf 'false'; return; }
        [ "$v" = "true" ] && { printf 'true'; return; }
    fi
    printf 'true'
}

n1_review_narrow_threshold_codex() {
    # Prints integer. Default: 100. Used when Codex is the active host.
    local v; v=$(n1_config_val '.review.narrowThresholdCodexMode')
    printf '%s' "${v:-100}"
}

n1_ci_checks_val() {
    # Usage: n1_ci_checks_val <key>
    # Keys: enabled, maxFixAttempts, confidenceThreshold
    local key="$1"
    # For boolean keys (enabled), n1_config_val's jq `// empty` treats false as falsy
    # and returns empty. Use direct jq query for the enabled key.
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r "if .ciChecks.${key} == null then \"absent\" else (.ciChecks.${key} | tostring) end" "$file" 2>/dev/null || true)
        if [ "$v" != "absent" ]; then printf '%s' "$v"; return; fi
    else
        local v; v=$(n1_config_val ".ciChecks.${key}")
        if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    fi
    case "$key" in
        enabled)             printf 'true' ;;
        maxFixAttempts)      printf '3' ;;
        confidenceThreshold) printf '0.7' ;;
        *)                   printf '' ;;
    esac
}

n1_cross_host_review_val() {
    # Usage: n1_cross_host_review_val <key>
    # Keys: enabled, autoTriage, maxFixAttempts, allowUnattended
    local key="$1"
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r --arg k "$key" 'if .crossHostReview[$k] == null then "absent" else (.crossHostReview[$k] | tostring) end' "$file" 2>/dev/null || true)
        if [ "$v" != "absent" ]; then printf '%s' "$v"; return; fi
    else
        local v; v=$(n1_config_val ".crossHostReview.${key}")
        if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    fi
    case "$key" in
        enabled)          printf 'true' ;;
        autoTriage)       printf 'false' ;;
        maxFixAttempts)   printf '1' ;;
        allowUnattended)  printf 'false' ;;
        *)                printf '' ;;
    esac
}

n1_escalation_val() {
    # Usage: n1_escalation_val <key>
    # Keys: alwaysAskOn, checkpoints
    local key="$1"
    local v; v=$(n1_config_val ".escalation.${key}")
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    case "$key" in
        alwaysAskOn)  printf '["security","architecture","public-api"]' ;;
        checkpoints)  printf '["pr"]' ;;
        *)            printf '' ;;
    esac
}

n1_memory_val() {
    # Usage: n1_memory_val <key>
    # Keys: ticketContext, decisions
    # Boolean keys — same jq `// empty` caveat as n1_ci_checks_val.
    local key="$1"
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r "if .memory.${key} == null then \"absent\" else (.memory.${key} | tostring) end" "$file" 2>/dev/null || true)
        if [ "$v" != "absent" ]; then printf '%s' "$v"; return; fi
    else
        local v; v=$(n1_config_val ".memory.${key}")
        if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    fi
    case "$key" in
        ticketContext) printf 'true' ;;
        decisions)     printf 'true' ;;
        *)             printf '' ;;
    esac
}

# Detect if running inside a linked git worktree NOT managed by N1.
# Returns 0 (true) when: git-dir diverges from git-common-dir (linked worktree)
# AND the worktree toplevel is NOT under the host worktree root (n1_worktree_root).
# Returns 1 (false) otherwise.
n1_is_external_worktree() {
    local git_dir git_common_dir toplevel
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
    # Resolve to absolute paths for reliable comparison
    git_dir=$(cd "$git_dir" && pwd -P)
    git_common_dir=$(cd "$git_common_dir" && pwd -P)
    # Not a linked worktree — git-dir and git-common-dir are the same
    [ "$git_dir" != "$git_common_dir" ] || return 1
    # It is a linked worktree — check if N1-managed
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    # Under the host's N1 worktree root → N1-managed
    local wt_root; wt_root=$(n1_worktree_root)
    case "$toplevel" in
        */"${wt_root}"/*) return 1 ;;
    esac
    # Linked worktree, not under the host worktree root — external
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

# Per-session active-run pointer (NP-206): $N1_HOME/active-run.<session_id>.json so concurrent
# sessions in one project never read each other's ticket/worktree/branch. No (or unsafe)
# session id -> unkeyed active-run.json. Read mode (no arg) falls back to the unkeyed file when
# this session's keyed file is absent (writer shell lacked the id); `write` always keys.
n1_active_run_file() {
    local home sid
    home=$(n1_home)
    [ -n "$home" ] || return 1
    sid=$(n1_session_id)
    case "$sid" in *[!a-zA-Z0-9_-]*) sid="" ;; esac   # same rule as n1_session_file
    if [ -n "$sid" ] && { [ "${1:-}" = write ] || [ -f "${home}/active-run.${sid}.json" ]; }; then
        printf '%s' "${home}/active-run.${sid}.json"
    else
        printf '%s' "${home}/active-run.json"
    fi
}

n1_active_run_write() {
    local ticket_id="$1" run_id="$2" worktree_path="${3:-null}" branch="${4:-}"
    local file
    file=$(n1_active_run_file write) || return 0
    local wt_val="null"
    [ "$worktree_path" != "null" ] && [ -n "$worktree_path" ] && wt_val="\"$(escape_json_val "$worktree_path")\""
    local esc_ticket esc_run esc_branch
    esc_ticket=$(escape_json_val "$ticket_id")
    esc_run=$(escape_json_val "$run_id")
    esc_branch=$(escape_json_val "$branch")
    cat > "$file" <<AREOF
{"ticketId":"${esc_ticket}","runId":"${esc_run}","worktreePath":${wt_val},"branch":"${esc_branch}"}
AREOF
}

n1_active_run_clear() {
    local file
    file=$(n1_active_run_file) || return 0
    rm -f "$file"
}
