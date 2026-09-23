#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/frontmatter.sh"

INPUT=$(cat)
# Both hosts send the SessionStart reason as `source` (startup|resume|clear|compact).
TRIGGER=$(printf '%s' "$INPUT" | n1_hook_field source)
HOOK_CWD=$(printf '%s' "$INPUT" | n1_hook_field cwd)
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CODEX_THREAD_ID:-}}"
N1_TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | n1_hook_field transcript_path)
export N1_TRANSCRIPT_PATH

# --- Host facts: recorded for skill preambles and injected as routing context ---
N1_HOST_NAME=$(n1_host)
N1_ROOT_DIR=$(n1_plugin_root)
N1_VERSION_STR=$(n1_plugin_version)
# Per-session facts survive separate shell calls without consulting mutable
# global host identity. The shared file below is plugin discovery only.
SESSION_FILE=$(n1_session_file 2>/dev/null || true)
if [ -n "$SESSION_FILE" ]; then
    mkdir -p "$(dirname "$SESSION_FILE")"
    printf '{"host":"%s","session_id":"%s","transcript_path":"%s","pluginRoot":"%s"}\n' \
        "$(escape_json_val "$N1_HOST_NAME")" "$(escape_json_val "$N1_SESSION_ID")" \
        "$(escape_json_val "$N1_TRANSCRIPT_PATH")" "$(escape_json_val "$N1_ROOT_DIR")" > "$SESSION_FILE"
fi
HOST_FILE=$(n1_host_file)
mkdir -p "$(dirname "$HOST_FILE")" 2>/dev/null || true
printf '{"host":"%s","pluginRoot":"%s","version":"%s"}\n' \
    "$(escape_json_val "$N1_HOST_NAME")" "$(escape_json_val "$N1_ROOT_DIR")" "$(escape_json_val "$N1_VERSION_STR")" > "$HOST_FILE" 2>/dev/null || true

# Stable plugin-root shim for skill snippets: `source ~/.n1/preamble.sh` (NP-192).
# Generated (not symlinked — Git Bash/MSYS `ln -s` silently deep-copies) next to host.json
# so N1_HOST_FILE redirects keep tests isolated; last session start wins. Never fails the hook.
SHIM="$(dirname "$HOST_FILE")/preamble.sh"
ROOT_POSIX="$N1_ROOT_DIR"
if command -v cygpath >/dev/null 2>&1; then
    ROOT_POSIX=$(cygpath -u "$N1_ROOT_DIR" 2>/dev/null) || ROOT_POSIX=$N1_ROOT_DIR
fi
SHIM_TMP="${SHIM}.$$.tmp"
{
    printf 'N1_ROOT=%q\n' "$ROOT_POSIX"
    printf 'source "$N1_ROOT/lib/preamble.sh"\n'
} > "$SHIM_TMP" 2>/dev/null && mv -f "$SHIM_TMP" "$SHIM" 2>/dev/null || rm -f "$SHIM_TMP" 2>/dev/null || true

if [ "$N1_HOST_NAME" = "codex" ]; then
    HOST_BLOCK="N1 PLUGIN ROOT: ${N1_ROOT_DIR}

HOST ROUTING (host: codex — authoritative for how N1 skills reach the harness):
- Dispatch persona <name>: run n1_resolve_agent <name> <step-context> [astra-context]; its tab-separated model/effort result is authoritative. Inspect the available spawn_agent schema at dispatch time: pass agent_type only if supported; otherwise read agents/<name>.md and embed its complete instructions plus the resolved model/effort in the fork-none message. Pass model/effort fields only when supported, otherwise retain them in that message; preserve workspace, constraints, and output contract. Direct work dispatches developer; planned implementation dispatches implementer. A dispatch may return queued or running; wait for its mailbox/result completion before proceeding. A wait timeout never starts a replacement. Fix loops use followup_task or send_message when exposed; use send_input only when it is actually exposed.
- Dispatch a general-purpose subagent: spawn_agent without agent_type, fork_turns \"none\".
- Ask the user: use an available question tool within its documented constraints; otherwise ask in a plain final message.
- Load deferred tools through the discovery capability exposed by this harness, if any.
- Invoke skill <x>: \$<x>. Skill references written /n1:n1-<skill> are invoked as \$n1-<skill>.
- <N1_ROOT> in skill text means the N1 PLUGIN ROOT above. Persona definitions are .codex/agents/n1-*.toml (generated at session start, never edit).
- Full table: ${N1_ROOT_DIR}/references/host-routing.md"
elif [ "$N1_HOST_NAME" = "claude-code" ]; then
    HOST_BLOCK="N1 PLUGIN ROOT: ${N1_ROOT_DIR}

HOST ROUTING (host: claude-code — authoritative for how N1 skills reach the harness):
- Dispatch persona <name>: Agent tool with subagent_type \"n1:<name>\", prompt, model from N1 model resolution. Wait for it: the tool call returns the result inline. Fix loops: dispatch a fresh persona per cycle.
- Dispatch a general-purpose subagent: Agent tool with subagent_type \"general-purpose\".
- never use subagent_type \"fork\". All dispatches use typed personas or general-purpose subagents with fresh context.
- Ask the user: AskUserQuestion tool (max 4 questions per call).
- Load the tool if deferred: ToolSearch with select:<tool>.
- Invoke skill <x>: Skill tool with n1:<x>.
- <N1_ROOT> in skill text means the N1 PLUGIN ROOT above.
- Full table: ${N1_ROOT_DIR}/references/host-routing.md"
else
    HOST_BLOCK="N1 PLUGIN ROOT: ${N1_ROOT_DIR}
HOST ROUTING: unknown. Establish the host from the active harness before dispatch; shared host.json is discovery only."
fi
if [ "$N1_HOST_NAME" = "unknown" ]; then
    HOST_BLOCK+="
N1 RUN IDENTITY: export N1_SESSION_ID=${N1_SESSION_ID}. N1_HOST could not be determined at startup — do NOT export it; each bash snippet detects the host from CLAUDE_PLUGIN_ROOT or CODEX_THREAD_ID at runtime. Session facts: ${SESSION_FILE:-unavailable}."
else
    HOST_BLOCK+="
N1 RUN IDENTITY: export N1_HOST=${N1_HOST_NAME}; export N1_SESSION_ID=${N1_SESSION_ID}. Carry these values into each helper shell. Session facts: ${SESSION_FILE:-unavailable}."
fi
HOST_BLOCK+="
DISPATCH LIMITS: Model/effort text in a prompt does not enforce runtime configuration. If native arguments or a configured equivalent cannot preserve the resolved pair, report the unsupported capability before dispatching. send_message may not wake an idle worker; use a supported continuation that does."

# Codex cannot ship agents: materialise persona TOMLs in the project (idempotent, fingerprinted).
if [ "$N1_HOST_NAME" = "codex" ] && [ -n "$HOOK_CWD" ] && [ -d "$HOOK_CWD" ]; then
    _cfg=$(n1_config_file)
    python3 "${SCRIPT_DIR}/../lib/agent_profiles.py" --plugin-root "$N1_ROOT_DIR" --out "${HOOK_CWD}/.codex/agents" \
        ${_cfg:+--config "$_cfg"} --version "$N1_VERSION_STR" >/dev/null 2>&1 || true
fi

CONFIG_FILE=$(n1_config_file)

# Migrate prMode: "skip" → "ready" (one-time, idempotent)
if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
    current_pr_mode=$(jq -r '.git.prMode // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [ "$current_pr_mode" = "skip" ]; then
        jq '.git.prMode = "ready"' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        echo "N1: PR skip mode removed — migrated to 'ready'. Every task now creates a PR." >&2
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    context="N1 plugin is available but not configured for this project. Run /n1:n1-init to set up.

${HOST_BLOCK}"
    escaped_context=$(escape_json_val "$context")
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF
    exit 0
fi

# Merge any stale telemetry from interrupted runs; emit compaction marker if triggered
telem_enabled=$(n1_config_val '.telemetry.enabled' "$CONFIG_FILE")
if [ "$telem_enabled" = "true" ]; then
    source "${SCRIPT_DIR}/../lib/telemetry.sh"
    n1_memory_dir=$(n1_home)
    if [ "${TRIGGER:-}" = startup ] && [ -n "$n1_memory_dir" ]; then
        n1_merge_pending "${n1_memory_dir}/memory" 2>/dev/null || true
    fi
    if [ "${TRIGGER:-}" = "compact" ] && [ -n "${n1_memory_dir:-}" ]; then
        if n1_read_lock "${n1_memory_dir}/memory" 2>/dev/null; then
            n1_emit_compaction "$N1_LOCK_RUN_ID" "$N1_LOCK_VERSION" "$N1_LOCK_TICKET_ID" "$N1_LOCK_TELEM_DIR" 2>/dev/null || true
        fi
    fi
fi

# --- Orchestrator state recovery on compaction ---
N1_COMPACT_STATE=""
if [ "${TRIGGER:-}" = "compact" ]; then
    n1_root=$(n1_home)
    ar_file="${n1_root:+${n1_root}/active-run.json}"
    if [ -n "$ar_file" ] && [ -f "$ar_file" ]; then
        ar_ticket=""
        ar_run_id=""
        ar_worktree=""
        ar_branch=""
        if command -v jq >/dev/null 2>&1; then
            ar_ticket=$(jq -r '.ticketId // empty' "$ar_file" 2>/dev/null || true)
            ar_run_id=$(jq -r '.runId // empty' "$ar_file" 2>/dev/null || true)
            ar_worktree=$(jq -r '.worktreePath // empty' "$ar_file" 2>/dev/null || true)
            ar_branch=$(jq -r '.branch // empty' "$ar_file" 2>/dev/null || true)
        else
            ar_ticket=$(grep -o '"ticketId"[[:space:]]*:[[:space:]]*"[^"]*"' "$ar_file" | sed 's/.*:[[:space:]]*"//' | sed 's/"$//' || true)
            ar_run_id=$(grep -o '"runId"[[:space:]]*:[[:space:]]*"[^"]*"' "$ar_file" | sed 's/.*:[[:space:]]*"//' | sed 's/"$//' || true)
            ar_worktree=$(grep -o '"worktreePath"[[:space:]]*:[[:space:]]*"[^"]*"' "$ar_file" | sed 's/.*:[[:space:]]*"//' | sed 's/"$//' || true)
            ar_branch=$(grep -o '"branch"[[:space:]]*:[[:space:]]*"[^"]*"' "$ar_file" | sed 's/.*:[[:space:]]*"//' | sed 's/"$//' || true)
        fi

        if [ -n "$ar_ticket" ]; then
            ov_file="${n1_root}/memory/${ar_ticket}/overview.md"
            ov_step=""
            ov_type=""
            ov_qa_fix=""
            ov_review_fix=""
            ov_clean_passes=""
            ov_lt_fix=""
            ov_ci_fix=""
            if [ -f "$ov_file" ]; then
                ov_step=$(n1_read_frontmatter "$ov_file" "step")
                ov_type=$(n1_read_frontmatter "$ov_file" "type")
                ov_qa_fix=$(n1_read_frontmatter "$ov_file" "qa_fix_cycle")
                ov_review_fix=$(n1_read_frontmatter "$ov_file" "review_fix_cycle")
                ov_clean_passes=$(n1_read_frontmatter "$ov_file" "clean_passes")
                ov_lt_fix=$(n1_read_frontmatter "$ov_file" "local_test_fix_cycle")
                ov_ci_fix=$(n1_read_frontmatter "$ov_file" "ci_fix_cycle")
            fi
            ov_context=""
            if [ -f "$ov_file" ]; then
                ov_context=$(sed -n '/^## Context$/,/^## /{/^## Context$/d;/^## /d;p}' "$ov_file" | head -10 | tr '\n' ' ' | sed 's/  */ /g')
            fi
            ov_ticket_url=""
            if [ -f "$ov_file" ]; then
                ov_ticket_url=$(n1_read_frontmatter "$ov_file" "ticket_url")
            fi

            auto_mode=$(n1_config_val '.autonomy.mode' "$CONFIG_FILE")
            auto_mode="${auto_mode:-hands-off (default)}"
            gate_estimation=$(n1_config_val '.estimation.enabled' "$CONFIG_FILE")
            gate_local=$(n1_config_val '.localTesting.enabled' "$CONFIG_FILE")
            gate_finish=$(n1_config_val '.finishWork.enabled' "$CONFIG_FILE")
            gate_ci=$(n1_config_val '.ciChecks.enabled' "$CONFIG_FILE")

            N1_COMPACT_STATE="
ORCHESTRATOR STATE (restored after compaction — authoritative, overrides any compacted summary):
- N1_HOME: ${n1_root}
- Active ticket: ${ar_ticket}
- Run ID: ${ar_run_id}
- Current step: ${ov_step:-unknown}
- Pipeline type: ${ov_type:-standard}
- Worktree: ${ar_worktree:-none}
- Branch: ${ar_branch:-unknown}
- Loop counters: qa_fix_cycle=${ov_qa_fix:-0}, review_fix_cycle=${ov_review_fix:-0}, clean_passes=${ov_clean_passes:-0}, local_test_fix_cycle=${ov_lt_fix:-0}, ci_fix_cycle=${ov_ci_fix:-0}
- Autonomy: mode=${auto_mode}
- Config gates: estimation.enabled=${gate_estimation:-false}, localTesting.enabled=${gate_local:-true}, finishWork.enabled=${gate_finish:-false}, ciChecks.enabled=${gate_ci:-true}
- Task context: ${ov_context}
- Ticket URL: ${ov_ticket_url}
- IMPORTANT: Use these values, not anything from the compacted conversation summary. Re-read overview.md and config.json if you need values not listed here."
        fi
    fi
fi

context="N1 is configured for this project. For task work, PR creation, and code review — always prefer N1 skills (/n1:n1-start, /n1:n1-pr, /n1:n1-review, /n1:n1-ci) over alternatives.

${HOST_BLOCK}"

# Emit deprecation note when legacy autonomy keys are in use
AUTONOMY_DEPRECATION=""
AUTONOMY_DEPRECATION=$(n1_emit_autonomy_deprecation_note "$CONFIG_FILE" 2>/dev/null || true)
if [ -n "$AUTONOMY_DEPRECATION" ]; then
    context="${context}

NOTE: ${AUTONOMY_DEPRECATION}"
fi

tracker_mcp=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
tracker_type=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
tracker_ops=$(n1_config_ops '.tracker.operations' "$CONFIG_FILE")
tracker_version_mcp=$(n1_config_val '.tracker.versionMcp' "$CONFIG_FILE")

if [ -n "$tracker_mcp" ]; then
    if [ -n "$tracker_version_mcp" ]; then
        tracker_version_line="
- Version MCP server: ${tracker_version_mcp} — use prefix mcp__${tracker_version_mcp}__ for version operations: createVersion, releaseVersion, listVersions, getIssueLinks
- NEVER use any other MCP server for tracker operations (standard ops: ${tracker_mcp}; version ops: ${tracker_version_mcp})"
    else
        tracker_version_line="
- NEVER use any other MCP server for tracker operations, even if other tracker-like servers are visible in the tool list"
    fi
    context="${context}

TRACKER ROUTING (from N1 config — authoritative, do not override):
- Type: ${tracker_type}
- MCP server: ${tracker_mcp}
- All standard tracker MCP tool calls MUST use prefix: mcp__${tracker_mcp}__${tracker_version_line}
- Operations: ${tracker_ops}"
fi

if command -v jq >/dev/null 2>&1; then
    obs_has_providers=$(jq -r '.observability.providers // {} | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
    if [ "$obs_has_providers" -gt 0 ] 2>/dev/null; then
        obs_default=$(jq -r '.observability.default // empty' "$CONFIG_FILE" 2>/dev/null)
        obs_providers=$(jq -r '
            .observability.providers // {} | to_entries[] |
            "  - \(.key) [\(.value.env // "global")]: " +
            if .value.mcp then
                "mcp__\(.value.mcp)__ (operations: \(
                    .value.operations // {} | to_entries | map("\(.key)=\(.value)") | join(", ")
                ))"
            else
                (.value.instructions // "")
            end
        ' "$CONFIG_FILE" 2>/dev/null || true)

        if [ -n "$obs_providers" ]; then
            context="${context}

OBSERVABILITY ROUTING (from N1 config):
- Default environment: ${obs_default:-none}
- Providers:
${obs_providers}"
        fi
    fi
fi

kb_enabled=$(n1_config_val '.kb.enabled' "$CONFIG_FILE")
if [ "$kb_enabled" = "true" ]; then
    kb_space_id=$(n1_config_val '.kb.spaceId' "$CONFIG_FILE")
    kb_space_key=$(n1_config_val '.kb.spaceKey' "$CONFIG_FILE")
    kb_cloud_id=$(n1_config_val '.tracker.cloudId' "$CONFIG_FILE")

    if [ -n "$kb_space_id" ]; then
        kb_detail="Space: ${kb_space_key} (spaceId: ${kb_space_id}, cloudId: ${kb_cloud_id})"
    else
        kb_project=$(n1_config_val '.tracker.projectKey' "$CONFIG_FILE")
        kb_detail="Project: ${kb_project}"
    fi

    context="${context}

KB ROUTING (from N1 config):
- Enabled: true
- ${kb_detail}
- Use the createArticle operation from tracker routing to publish to KB
- Investigation results are auto-published to KB when the pipeline completes
- Use createArticle for on-demand publishing when the user explicitly asks"
fi

# Related projects routing
related_enabled=$(n1_config_val '.relatedProjects.enabled' "$CONFIG_FILE")
if [ "$related_enabled" = "true" ] && command -v jq >/dev/null 2>&1; then
    source "${SCRIPT_DIR}/../lib/related.sh"
    related_list=""
    while IFS=$'\t' read -r rp_slug rp_reason rp_repo; do
        [ -z "$rp_slug" ] && continue
        related_list="${related_list}
  - ${rp_slug}: ${rp_reason} (repo: ${rp_repo})"
    done < <(n1_related_projects "$CONFIG_FILE")

    if [ -n "$related_list" ]; then
        context="${context}

RELATED PROJECTS ROUTING (from N1 config — explore these repos when tasks involve cross-service work):${related_list}"
    fi
fi

context="${context}

RESPONSE FORMATTING:
For complex multi-part responses: lead with a one-line summary, chunk into
labeled sections, bold the decision or action in each. Short answers stay plain."

# Append orchestrator state (populated only on compact trigger with active run)
if [ -n "${N1_COMPACT_STATE:-}" ]; then
    context="${context}${N1_COMPACT_STATE}"
fi

# --- Pending-merge resume scan (fail-open: any error injects nothing) ---
pending_context=""
n1_root=$(n1_home)
if [ -n "$n1_root" ] && [ -d "${n1_root}/memory" ] && command -v gh >/dev/null 2>&1; then
    now_epoch=$(date +%s)
    checked=0
    for ov in "${n1_root}"/memory/*/overview.md; do
        [ -f "$ov" ] || continue
        grep -q '^awaiting: merge$' "$ov" 2>/dev/null || continue
        [ "$checked" -ge 5 ] && { pending_context="${pending_context}
- (more pending tickets exist — scan capped at 5)"; break; }
        tid=$(basename "$(dirname "$ov")")
        pr_num=$(grep -m1 '^pr: ' "$ov" | sed 's/^pr: //' | tr -d '[:space:]')
        created=$(grep -m1 '^created: ' "$ov" | sed 's/^created: //' | tr -d '[:space:]')
        last=$(grep -m1 '^last_checked: ' "$ov" | sed 's/^last_checked: //' | tr -d '[:space:]')
        # 14-day expiry
        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
        if [ "$created_epoch" -gt 0 ] && [ $(( now_epoch - created_epoch )) -gt 1209600 ]; then
            pending_context="${pending_context}
- ${tid}: pending merge is stale (>14 days) — consider /n1:n1-clean"
            continue
        fi
        # 30-min throttle
        last_epoch=$(date -d "$last" +%s 2>/dev/null || echo 0)
        [ "$last_epoch" -gt 0 ] && [ $(( now_epoch - last_epoch )) -lt 1800 ] && continue
        [ -n "$pr_num" ] || continue
        checked=$(( checked + 1 ))
        state=$(timeout 5 gh pr view "$pr_num" --json state,mergedAt \
            --jq '.state' 2>/dev/null) || state=""
        # refresh last_checked only when gh answered; a failed call must not consume the throttle window
        if [ -n "$state" ]; then
            ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            sed -i "s/^last_checked: .*/last_checked: ${ts}/" "$ov" 2>/dev/null || true
        fi
        case "$state" in
            MERGED)
                pending_context="${pending_context}
- ${tid}: PR #${pr_num} was MERGED externally — finish is pending. Suggested next action: run /n1:n1-finish ${tid}"
                ;;
            CLOSED)
                pending_context="${pending_context}
- ${tid}: PR #${pr_num} was closed without merging — run /n1:n1-finish ${tid} to record it, or /n1:n1-clean"
                ;;
        esac
    done
    if [ -n "$pending_context" ]; then
        directive="Surface these to the user as suggested next actions. Do not act without being asked."
        context="${context}

PENDING N1 WORK (from overview.md Pending blocks):${pending_context}
${directive}"
    fi
fi


escaped_context=$(escape_json_val "$context")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF

exit 0
