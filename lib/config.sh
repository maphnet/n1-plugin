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
    # so boolean gates like localTesting.enabled work without jq.
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

_n1_agent_frontmatter() {
    # Usage: _n1_agent_frontmatter <persona> <model|effort>
    local persona="$1" key="$2" agent_file
    agent_file="$(n1_plugin_root)/agents/${persona}.md"
    [ -f "$agent_file" ] || return 0
    awk -v key="$key" 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { exit } in_fm && $0 ~ "^" key ":[[:space:]]*" { sub("^" key ":[[:space:]]*", ""); gsub(/\r/, ""); print; exit }' "$agent_file"
}

_n1_known_role() {
    local role
    role=$(_n1_agent_frontmatter "$1" model)
    case "$role" in opus|sonnet|haiku) printf '%s' "$role";; esac
}

_n1_model_override() {
    # Usage: _n1_model_override <persona> — models.<persona> from config, or empty.
    # Plain string. A pre-4.0 host-keyed object is read through its "claude-code" key.
    local persona="$1" config_file
    config_file=$(n1_config_file)
    [ -f "$config_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg p "$persona" '
            .models[$p] as $e |
            if ($e|type) == "string" then $e
            elif ($e|type) == "object" then ($e["claude-code"] | if type == "string" then . elif type == "object" then (.model // empty) else empty end)
            else empty end' "$config_file" 2>/dev/null || true
    else
        n1_config_val ".models.${persona}" "$config_file"
    fi
}

n1_model_for() {
    # Usage: n1_model_for <persona> — the model to spawn this persona with.
    local persona="$1" v role
    role=$(_n1_known_role "$persona")
    if [ -n "$role" ]; then n1_resolve_model "$persona"; return; fi
    v=$(_n1_model_override "$persona")
    if [ -n "$v" ]; then printf '%s' "$v"; return; fi
    printf 'sonnet'
}

n1_resolve_model() {
    local agent_name="$1"
    local context="${2:-}"
    local override=""
    local config_file
    config_file=$(n1_config_file)

    # 1. Config override (always wins)
    override=$(_n1_model_override "$agent_name")
    if [ -n "$override" ]; then printf '%s' "$override"; return; fi

    # Get base model from agent frontmatter
    local base_model
    base_model=$(_n1_known_role "$agent_name")
    if [ -z "$base_model" ]; then
        printf 'sonnet'; return
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
                n1_resolve_tier "$trigger_tier" "$base_model"
                return
            fi

            # Evaluate condition; requires memory dir
            if [ -n "$mem_dir" ] && [ -d "$mem_dir" ]; then
                type n1_record_decision >/dev/null 2>&1 || source "$(n1_plugin_root)/lib/telemetry.sh" 2>/dev/null || true
                local dec_id="${section%_triggers}:${trigger_key}"   # e.g. escalation:developer:implementation
                if n1_eval_signal_gate "$mem_dir" "$overview_file" "$trigger_cond"; then
                    n1_record_decision "$dec_id" true "$trigger_cond" "tier=${trigger_tier}" 2>/dev/null || true
                    n1_resolve_tier "$trigger_tier" "$base_model"
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
                    n1_resolve_tier "$profile_tier" "$base_model"
                    return
                fi
            fi
        fi
    fi

    # 4. Agent frontmatter default
    printf '%s' "$base_model"
}

n1_resolve_agent() {
    # Usage: n1_resolve_agent <persona> [step-context] — prints "<model>\t<effort>".
    # Effort is always empty on Claude Code; the column stays so tab-splitting callers are unchanged.
    printf '%s\t\n' "$(n1_resolve_model "$1" "${2:-}")"
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
                    acceptanceGate)     printf 'auto';        return ;;
                    escalationMargin)   printf '0.05';        return ;;
                esac
                ;;
            interactive)
                case "$key" in
                    brainstorm)         printf 'interactive'; return ;;
                    mechanicalPrompts)  printf 'ask';         return ;;
                    qualityEscalations) printf 'block';       return ;;
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
    # Prints true/false; exit code agrees (0 only when true). The autonomous env preset always disables the plan checkpoint.
    if [ "${N1_AUTONOMY_PRESET:-}" = "autonomous" ]; then printf 'false'; return 1; fi
    local v; v=$(n1_config_val '.planReview.requirePlanApproval')
    [ "$v" = "true" ] && printf 'true' || printf 'false'
    [ "$v" = "true" ]
}

n1_post_deploy_verification_enabled() {
    # Prints true/false. An explicit boolean owns the gate; only an absent key may
    # fall back to legacy smoke mode. Invalid explicit values fail closed.
    local file state
    file=$(n1_config_file)
    if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
        printf 'false'
        return
    fi
    state=$(jq -r '
        if (.finishWork? | type) == "object"
          and (.finishWork.postDeployVerification? | type) == "object"
          and (.finishWork.postDeployVerification | has("enabled"))
        then (.finishWork.postDeployVerification.enabled | if type == "boolean" then . else "invalid" end)
        else "absent"
        end
    ' "$file" 2>/dev/null || printf 'invalid')
    case "$state" in
        true|false) printf '%s' "$state"; return ;;
        invalid) printf 'false'; return ;;
    esac
    [ "$(n1_config_val '.localTesting.mode')" = "smoke" ] && printf 'true' || printf 'false'
}

n1_merge_allowed() {
    # Exit 0 = this run may merge its PR / branch and chains into n1-finish; exit 1 = it stops after PR + CI.
    # Only queue children (N1_QUEUE_RUN_ID, exported by lib/queue.sh) with queue.mergeOnFinish=true.
    # Interactive runs never merge: the human merges, then runs /n1:n1-finish (N1-113).
    [ -n "${N1_QUEUE_RUN_ID:-}" ] && [ "$(n1_config_val '.queue.mergeOnFinish')" = "true" ]
}

n1_delivery_action() {
    # NP-219. Prints none | runbook | execute for the n1-finish delivery step.
    # none: delivery.mode is not "ssh" (absent/empty/unknown) -> the step is a no-op.
    # runbook: queue children and headless runs never execute delivery.command; they leave
    #   a runbook for the human (no auto-resolved confirm prompt can approve a deploy).
    #   Also forced when jq is unavailable: the grep/awk config-value fallback mis-parses
    #   escaped quotes, so its output must never be executed (SEC-3).
    # execute: interactive runs ask, execute, verify.
    # Without jq the fallback cannot read compact JSON, so any "delivery" key fails closed
    # to runbook; none only when the config has no delivery block at all.
    if ! command -v jq >/dev/null 2>&1; then
        if grep -q '"delivery"[[:space:]]*:' "$(n1_config_file)" 2>/dev/null; then printf 'runbook'; else printf 'none'; fi
        return 0
    fi
    if [ "$(n1_config_val '.delivery.mode')" != "ssh" ]; then printf 'none'; return 0; fi
    if [ -n "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" = "1" ]; then printf 'runbook'; return 0; fi
    printf 'execute'
}

n1_delivery_is_multi_step() {
    # NP-240. Prints true when delivery is an ordered delivery.steps list (an array, even an
    # empty one) and delivery.command is empty; false otherwise. command wins when both are
    # set: a hand-edited dual config degrades to the older single-command path.
    # Needs jq; prints false without it (n1_delivery_action already forces runbook then).
    local f
    f=$(n1_config_file)
    if ! command -v jq >/dev/null 2>&1 || [ ! -f "$f" ]; then printf 'false'; return 0; fi
    jq -r 'if ((.delivery.command // "") == "") and ((.delivery.steps | type) == "array")
           then "true" else "false" end' "$f" 2>/dev/null || printf 'false'
}

n1_delivery_step() {
    # NP-240. Usage: n1_delivery_step <index> <cmd-file>
    # Classifies delivery.steps[index] with the references/deployment-actions.md grammar:
    # "Manual:" prefix -> manual; starts with a backtick, exactly two backticks, non-empty
    # command -> shell; anything else -> manual. Line 1: shell | manual | end; lines 2+:
    # the item text. shell writes the extracted command to <cmd-file> so the bytes shown and
    # the bytes run are identical. NEVER executes anything. Needs jq (execute branch only).
    local idx="$1" out="$2" f n item nbt cmd=""
    rm -f "$out"
    case "$idx" in ''|*[!0-9]*) printf 'end\n'; return 0 ;; esac
    if [ "$(n1_delivery_is_multi_step)" != "true" ]; then printf 'end\n'; return 0; fi
    f=$(n1_config_file)
    n=$(jq -r '.delivery.steps | length' "$f" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$idx" -ge "$n" ]; then printf 'end\n'; return 0; fi
    item=$(jq -r --argjson i "$idx" '.delivery.steps[$i] | if type == "string" then . else tojson end' "$f" 2>/dev/null)
    nbt=$(printf '%s' "$item" | tr -dc '`' | wc -c)
    case "$item" in
        'Manual:'*) ;;
        '`'*) if [ "$nbt" -eq 2 ]; then cmd=$(printf '%s' "$item" | awk -F'`' '{ printf "%s", $2 }'); fi ;;
    esac
    if [ -n "$cmd" ]; then
        printf '%s' "$cmd" > "$out"
        printf 'shell\n%s\n' "$item"
    else
        printf 'manual\n%s\n' "$item"
    fi
}

n1_delivery_runbook() {
    # NP-219. Usage: n1_delivery_runbook <ID> [merge-sha] [first-step]
    # Writes $N1_HOME/memory/<ID>/runbook.md with the configured deploy/verify commands and
    # sets overview.md deploy_pending: true (+ deploy_merge_sha when the merge already
    # happened, so `n1-finish <ID>` skips straight to the deploy). NEVER executes either
    # command. Prints the runbook path. Needs frontmatter.sh (loaded by the preamble).
    # NP-240: with delivery.steps, lists the steps from index <first-step> (default 0) and
    # records it as overview deploy_next_step, so a resumed walk starts there and steps
    # that already ran are never offered again.
    local id="$1" sha="${2:-}" first="${3:-0}" dir ov cmd verify multi
    case "$first" in ''|*[!0-9]*) first=0 ;; esac
    dir="$N1_HOME/memory/$id"; ov="$dir/overview.md"
    mkdir -p "$dir"
    cmd=$(n1_config_val '.delivery.command')
    verify=$(n1_config_val '.delivery.verifyCommand')
    multi=$(n1_delivery_is_multi_step)
    {
        printf '# Deploy runbook: %s\n\n' "$id"
        if [ -n "$sha" ]; then
            printf 'Merged at `%s`. The deploy is pending.\n\n' "$sha"
        else
            printf 'Not merged yet. `n1-finish %s` confirms (or performs) the merge first, then deploys.\n\n' "$id"
        fi
        if [ "$multi" = "true" ]; then
            printf 'Run interactively: `n1-finish %s`. It asks before each step, starting at step %s, runs the verify command, and closes the ticket on success.\n\n' "$id" "$((first + 1))"
            printf 'Deploy steps (`Manual:` steps are done by hand; the others are shell commands):\n\n'
            jq -r --argjson f "$first" '.delivery.steps | to_entries[] | select(.key >= $f)
                | "\(.key + 1). \(.value | if type == "string" then . else tojson end)"' "$(n1_config_file)" 2>/dev/null
        else
            printf 'Run interactively: `n1-finish %s`. It asks to confirm, runs the deploy, runs the verify command, and closes the ticket on success.\n\n' "$id"
            if [ -n "$cmd" ]; then
                printf 'Deploy command:\n\n```\n%s\n```\n' "$cmd"
            else
                printf 'Deploy: not rendered here (jq is unavailable or delivery has no command). See `delivery` in the N1 config.json.\n'
            fi
        fi
        if [ -n "$verify" ]; then
            printf '\nVerify command:\n\n```\n%s\n```\n' "$verify"
        fi
    } > "$dir/runbook.md"
    if [ ! -f "$ov" ]; then printf -- '---\n---\n' > "$ov"; fi
    n1_write_frontmatter "$ov" deploy_pending true
    if [ -n "$sha" ]; then n1_write_frontmatter "$ov" deploy_merge_sha "$sha"; fi
    if [ "$multi" = "true" ]; then n1_write_frontmatter "$ov" deploy_next_step "$first"; fi
    printf '%s\n' "$dir/runbook.md"
}

n1_review_narrow_threshold() {
    # Prints integer. Default: 50.
    local v; v=$(n1_config_val '.review.narrowThreshold')
    printf '%s' "${v:-50}"
}

n1_review_skip_doc_config() {
    # Prints true/false. Default: true.
    # n1_config_val (NP-213) already null-checks and distinguishes explicit false from
    # absent; this local jq call is kept for the tri-state "absent" fallback text below.
    local file; file=$(n1_config_file)
    if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
        local v; v=$(jq -r 'if .review.skipDocConfigOnly == null then "absent" else (.review.skipDocConfigOnly | tostring) end' "$file" 2>/dev/null || true)
        [ "$v" = "false" ] && { printf 'false'; return; }
        [ "$v" = "true" ] && { printf 'true'; return; }
    fi
    printf 'true'
}

n1_compose_file() {
    # Usage: n1_compose_file [dir]. Prints the first matching root compose filename and returns 0,
    # or prints nothing and returns 1. Single source of truth for the compose-name list (NP-222) --
    # n1_resolve_local_testing_mode, hooks/session-start.sh's enable offer, and n1-init step 08 all
    # call this instead of each keeping their own copy of the list.
    local dir="${1:-.}" f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [ -f "$dir/$f" ]; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

n1_resolve_local_testing_mode() {
    # Usage: n1_resolve_local_testing_mode [repo_dir]
    # Prints the local-testing mode. Precedence: explicit localTesting.mode >
    # localTesting.autoLive=true + root compose file -> live > startCommand set -> live > test.
    local dir="${1:-.}" mode
    mode=$(n1_config_val '.localTesting.mode')
    if [ -n "$mode" ]; then printf '%s' "$mode"; return 0; fi
    if [ "$(n1_config_val '.localTesting.autoLive')" = "true" ] && n1_compose_file "$dir" >/dev/null; then
        printf 'live'; return 0
    fi
    if [ -n "$(n1_config_val '.localTesting.startCommand')" ]; then printf 'live'; return 0; fi
    printf 'test'
}

n1_copy_worktree_files() {
    # Usage: n1_copy_worktree_files <main_checkout> <worktree_path>
    # Copies each worktree.copyFiles entry (relative file path, e.g. ".env") from the main
    # checkout into a new worktree. Copies only when the destination is missing and the path is
    # git-ignored in the worktree (so it can never be committed). Rejects absolute paths and
    # '..' segments (config is user-authored, but an escape would write outside the worktree).
    # Missing sources are skipped. Prints the number of files copied; always returns 0.
    local src="$1" dst="$2" file f n=0
    file=$(n1_config_file)
    if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then printf '0'; return 0; fi
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            /*|[A-Za-z]:*) echo "N1: worktree.copyFiles entry rejected (absolute path): $f" >&2; continue ;;
        esac
        case "/$f/" in
            */../*) echo "N1: worktree.copyFiles entry rejected ('..' segment): $f" >&2; continue ;;
        esac
        [ -e "$dst/$f" ] && continue
        [ -f "$src/$f" ] || continue
        if ! git -C "$dst" check-ignore -q -- "$f" 2>/dev/null; then
            echo "N1: worktree.copyFiles entry skipped (not git-ignored in worktree): $f" >&2
            continue
        fi
        mkdir -p "$(dirname "$dst/$f")" && cp -p "$src/$f" "$dst/$f" && n=$((n + 1))
    done < <(jq -r '.worktree.copyFiles // [] | .[]? | strings' "$file" 2>/dev/null)
    printf '%s' "$n"
}

n1_cross_host_review_val() {
    # Usage: n1_cross_host_review_val <key>
    # Keys: enabled, autoTriage, maxFixAttempts
    # Defaults: enabled=true, autoTriage=true (explicit false opts out, N1-94), maxFixAttempts=1
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
        autoTriage)       printf 'true' ;;
        maxFixAttempts)   printf '1' ;;
        *)                printf '' ;;
    esac
}

n1_escalation_val() {
    # Usage: n1_escalation_val alwaysAskOn -- fixed stop list (N1-113).
    case "$1" in
        alwaysAskOn)  printf '["security","architecture","public-api"]' ;;
        *)            printf '' ;;
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

# N1-112: n1-finish Step 6 worktree + local-branch cleanup; prints status tokens, one per line, always returns 0.
# Usage: n1_finish_cleanup <branch> <merged-pr-head-oid|""> <defaultBranch>   (run from the feature checkout)
# A branch checked out in a worktree cannot be deleted, so the worktree goes first. N1-managed worktrees
# are force-removed; external ones only when clean and HEAD is in the merged result (oid, else <defaultBranch>),
# never forced. Branch: tip must be an ancestor of the merged result (oid, else <defaultBranch>), then -d; -D only when the tip equals the merged PR head oid (squash/rebase).
# After a removal the shell is left in the main checkout.
n1_finish_cleanup() {
    local branch="${1:-}" oid="${2:-}" def="${3:-}"
    local gd gcd main top err cur st keep="" force=""
    gd=$(cd "$(git rev-parse --git-dir 2>/dev/null)" 2>/dev/null && pwd -P) \
        && gcd=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) \
        && main=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') && [ -n "$main" ] \
        || { echo worktree:none; echo branch:none; return 0; }
    local G=(git --git-dir="$gcd")
    if [ "$gd" = "$gcd" ]; then echo "worktree:none"
    else
        top=$(git rev-parse --show-toplevel 2>/dev/null) || top=""; cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || cur=""
        if [ "$cur" != "$branch" ]; then echo "worktree:kept-other"
        else
            # Only a positive match under the main checkout's N1 worktree root is N1-managed; everything else is external (never forced).
            case "$top" in "$main/$(n1_worktree_root)"/*) force="--force" ;; esac
            if [ -z "$force" ]; then
                if ! st=$(git status --porcelain --ignored 2>/dev/null) || [ -n "$(grep -v '^!!' <<<"$st")" ]; then keep="dirty"
                elif [ -n "$st" ]; then keep="ignored files"
                elif ! git merge-base --is-ancestor HEAD "${oid:-refs/heads/$def}" 2>/dev/null; then keep="unmerged"; fi
            fi
            if [ -n "$keep" ]; then echo "worktree:kept ($keep)"
            elif err=$(cd / && "${G[@]}" worktree remove $force "$top" 2>&1); then echo "worktree:removed"; cd "$main" 2>/dev/null || true
            else keep="remove-failed"; echo "worktree:remove-failed (${err%%$'\n'*})"; fi
        fi
    fi
    if [ -n "$keep" ]; then echo "branch:kept (worktree kept)"
    elif [ -z "$branch" ] || [ "$branch" = "$def" ] || ! "${G[@]}" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then echo "branch:none"
    elif ! "${G[@]}" merge-base --is-ancestor "refs/heads/$branch" "${oid:-refs/heads/$def}" >/dev/null 2>&1; then echo "branch:kept (not merged)"
    elif "${G[@]}" branch -d -- "$branch" >/dev/null 2>&1; then echo "branch:deleted"
    elif [ -n "$oid" ] && [ "$("${G[@]}" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)" = "$oid" ] \
        && "${G[@]}" branch -D -- "$branch" >/dev/null 2>&1; then echo "branch:deleted"
    else echo "branch:kept (not merged)"; fi
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

n1_assign_gap_warn() {
    # Usage: n1_assign_gap_warn   (no args; always returns 0, fail-open like n1_config_val)
    local ttype atc missing=""
    ttype=$(n1_config_val ".tracker.type")
    case "$ttype" in ""|none) return 0 ;; esac
    atc=$(n1_config_val ".tracker.assignToCreator")
    [ "$atc" = "false" ] && return 0
    [ -n "$(n1_config_val ".tracker.operations.getCurrentUser")" ] || missing="getCurrentUser"
    [ -n "$(n1_config_val ".tracker.operations.assign")" ] || missing="${missing:+$missing and }assign"
    [ -n "$missing" ] || return 0
    printf 'Warning: tracker.assignToCreator is on but config lacks tracker.operations.%s; tickets will not be assigned. Run /n1:n1-init to add it, or set tracker.assignToCreator to false.\n' "$missing"
    return 0
}
