#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/frontmatter.sh"

INPUT=$(cat)
TRIGGER=$(echo "$INPUT" | grep -o '"trigger"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)"/\1/' || true)

CONFIG_FILE=$(n1_config_file)

if [ ! -f "$CONFIG_FILE" ]; then
    context="N1 plugin is available but not configured for this project. Run /n1:n1-init to set up."
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
    [ -n "$n1_memory_dir" ] && n1_merge_pending "${n1_memory_dir}/memory" 2>/dev/null || true
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
            ar_ticket=$(grep -o '"ticketId":"[^"]*"' "$ar_file" | sed 's/.*:"//' | sed 's/"$//')
            ar_run_id=$(grep -o '"runId":"[^"]*"' "$ar_file" | sed 's/.*:"//' | sed 's/"$//')
            ar_worktree=$(grep -o '"worktreePath":"[^"]*"' "$ar_file" | sed 's/.*:"//' | sed 's/"$//')
            ar_branch=$(grep -o '"branch":"[^"]*"' "$ar_file" | sed 's/.*:"//' | sed 's/"$//')
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

            cfg="${n1_root}/config.json"
            auto_brainstorm=$(n1_autonomy_val 'brainstorm')
            auto_tail=$(n1_autonomy_val 'tailChain')
            auto_mech=$(n1_autonomy_val 'mechanicalPrompts')
            gate_estimation=$(n1_config_val '.estimation.enabled' "$cfg")
            gate_local=$(n1_config_val '.localTesting.enabled' "$cfg")
            gate_finish=$(n1_config_val '.finishWork.enabled' "$cfg")
            gate_ci=$(n1_config_val '.ciChecks.enabled' "$cfg")

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
- Autonomy: brainstorm=${auto_brainstorm}, tailChain=${auto_tail}, mechanicalPrompts=${auto_mech}
- Config gates: estimation.enabled=${gate_estimation:-false}, localTesting.enabled=${gate_local:-false}, finishWork.enabled=${gate_finish:-true}, ciChecks.enabled=${gate_ci:-false}
- IMPORTANT: Use these values, not anything from the compacted conversation summary. Re-read overview.md and config.json if you need values not listed here."
        fi
    fi
fi

context="N1 is configured for this project. For task work, PR creation, and code review — always prefer N1 skills (/n1:n1-start, /n1:n1-pr, /n1:n1-review, /n1:n1-ci) over alternatives."

tracker_mcp=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
tracker_type=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
tracker_ops=$(n1_config_ops '.tracker.operations' "$CONFIG_FILE")
error_mcp=$(n1_config_val '.errorTracking.mcp' "$CONFIG_FILE")
error_ops=$(n1_config_ops '.errorTracking.operations' "$CONFIG_FILE")

if [ -n "$tracker_mcp" ]; then
    context="${context}

TRACKER ROUTING (from N1 config — authoritative, do not override):
- Type: ${tracker_type}
- MCP server: ${tracker_mcp}
- All tracker MCP tool calls MUST use prefix: mcp__${tracker_mcp}__
- NEVER use any other MCP server for tracker operations, even if other tracker-like servers are visible in the tool list
- Operations: ${tracker_ops}"
fi

if [ -n "$error_mcp" ]; then
    context="${context}

ERROR TRACKING ROUTING (from N1 config — authoritative, do not override):
- MCP server: ${error_mcp}
- All error tracking MCP tool calls MUST use prefix: mcp__${error_mcp}__
- NEVER use any other MCP server for error tracking operations
- Operations: ${error_ops}"
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
        # refresh last_checked regardless of outcome
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        sed -i "s/^last_checked: .*/last_checked: ${ts}/" "$ov" 2>/dev/null || true
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
        tail_chain=$(n1_autonomy_val 'tailChain')
        directive="Surface these to the user as suggested next actions. Do not act without being asked."
        if [ "$tail_chain" = "auto" ]; then
            directive="autonomy.tailChain is 'auto': immediately run /n1:n1-finish for each MERGED entry above (finish only — NEVER /n1:n1-release; releases are always manual)."
        fi
        context="${context}

PENDING N1 WORK (from overview.md Pending blocks):${pending_context}
${directive}"
    fi
fi

# --- Awaiting-reply scan (no network calls, fail-open) ---
if [ -n "$n1_root" ] && [ -d "${n1_root}/memory" ]; then
    reply_context=""
    now_epoch_r=$(date +%s)
    for ov_r in "${n1_root}"/memory/*/overview.md; do
        [ -f "$ov_r" ] || continue
        grep -q '^awaiting: reply$' "$ov_r" 2>/dev/null || continue
        tid_r=$(basename "$(dirname "$ov_r")")
        blocked_since=$(grep -m1 '^blocked_since: ' "$ov_r" | sed 's/^blocked_since: //' | tr -d '[:space:]' || true)
        blocked_epoch=$(date -d "$blocked_since" +%s 2>/dev/null || echo 0)
        if [ "$blocked_epoch" -gt 0 ] && [ $(( now_epoch_r - blocked_epoch )) -gt 1209600 ]; then
            reply_context="${reply_context}
- ${tid_r}: tracker escalation reply is stale (>14 days since ${blocked_since}) — consider /n1:n1-clean or re-escalating"
        else
            reply_context="${reply_context}
- ${tid_r}: blocked on tracker reply since ${blocked_since:-unknown} — run /n1:n1-start ${tid_r} after replying to the tracker comment"
        fi
    done
    if [ -n "$reply_context" ]; then
        context="${context}

AWAITING TRACKER REPLIES (N1 blocked, waiting for user response on tracker):${reply_context}
Reply to the tracker comment and then run /n1:n1-start <ID> to resume the pipeline."
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
