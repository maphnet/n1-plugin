#!/usr/bin/env bash
# N1 per-step choreography helpers
#
# n1_step_begin <step_name> <step_number>
#   Writes current_step: <step_name> to overview.md frontmatter (the running step, read by the queue status table).
#   Emits telemetry started_at. No-op with a one-line stderr note when N1_RUN_ID is absent after n1_bind_run_to_ticket.
#   Prints owner:live <sid> <pid> on stdout when another live session owns $ID (n1_owner_check, N1-308); headless then returns without writes.
#
# n1_step_end <step_name> <step_number> <outcome> [metadata_json]
#   1. Writes step: <step_name> to overview.md frontmatter and clears current_step
#   2. Ticks the progress checkbox for this step in overview.md
#   3. Reads $N1_HOME/memory/$ID/step_signals.tmp if present,
#      calls n1_write_signals against $N1_HOME/memory/$ID/<step_name>.md,
#      then deletes the tmp file.
#   Best-effort: sets the Orca workspace card comment "<step>: <outcome>" (unread on escalated/blocked).
#   4. Emits telemetry completed_at with outcome (and optional metadata JSON).
#
# n1_head_record <from_sha>
#   Emits a "head" step event {"head":<HEAD>,"from":<from_sha>} for the review-pin head chain (N1-184).
#
# Signal scratch file protocol:
#   Middle bash snippets write one key=value pair per line to:
#     $N1_HOME/memory/$ID/step_signals.tmp
#   n1_step_end reads and applies them, then deletes the file.
#   If the target memory file ($N1_HOME/memory/$ID/<step_name>.md) does not
#   exist, signal writing is silently skipped.

_N1_STEP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

type n1_emit_step_event  >/dev/null 2>&1 || source "${_N1_STEP_LIB_DIR}/telemetry.sh"
type n1_write_frontmatter >/dev/null 2>&1 || source "${_N1_STEP_LIB_DIR}/frontmatter.sh"
type n1_write_signals    >/dev/null 2>&1 || source "${_N1_STEP_LIB_DIR}/signals.sh"

# _n1_step_display_name <step_name>
# Returns the checkbox label text in overview.md's ## Progress section,
# or empty string for steps without a progress checkbox (fix, release, etc.)
_n1_step_display_name() {
    case "$1" in
        ticket)                    printf '%s' "Ticket read" ;;
        analysis)                  printf '%s' "Analysis" ;;
        brainstorm)                printf '%s' "Brainstorm" ;;
        plan)                      printf '%s' "Plan" ;;
        implementation)            printf '%s' "Implementation" ;;
        qa)                        printf '%s' "QA" ;;
        review)                    printf '%s' "Review" ;;
        local-testing)             printf '%s' "Local Testing" ;;
        plan-review)               printf '%s' "Plan Review" ;;
        pr)                        printf '%s' "PR" ;;
        ci)                        printf '%s' "CI" ;;
        investigation-deliverable) printf '%s' "Investigation deliverable" ;;
        *)                         printf '' ;;
    esac
}

# n1_step_begin <step_name> <step_number>
n1_step_begin() {
    local step_name="$1" step_number="$2" _o
    n1_bind_run_to_ticket                 # restored run must belong to $ID (N1-193)
    # Second live orchestrator on $ID (N1-308): live token on stdout for the model; silent otherwise.
    [ -n "${ID:-}" ] && { _o=$(n1_owner_check "$ID") || { echo "$_o"; [ "${N1_HEADLESS:-}" = 1 ] && return 0; }; }
    # Running step for the queue status table (N1-299); independent of the run binding.
    [ -f "${N1_HOME}/memory/${ID}/overview.md" ] && { n1_write_frontmatter "${N1_HOME}/memory/${ID}/overview.md" current_step "$step_name" || true; }
    # No run bound: say so on every call, so a lost begin is attributable (N1-229).
    [ -n "${N1_RUN_ID:-}" ] || { echo "n1_step_begin: no run bound for ${ID:-<unset>}; '$step_name' begin not recorded" >&2; return 0; }
    n1_emit_step_event "${N1_RUN_ID}" "${N1_VERSION:-}" "${ID:-}" \
        "$step_name" "$step_number" "${N1_HOME}/memory/${ID}/telemetry" \
        started_at=now
}

# n1_step_end <step_name> <step_number> <outcome> [metadata_json]
# outcome: success | skipped | failed | error
# metadata_json: optional raw JSON object, e.g. '{"planning_need":"plan"}'
n1_step_end() {
    local step_name="$1" step_number="$2" outcome="${3:-success}" metadata_json="${4:-}"

    # 1. Write step frontmatter and tick progress checkbox
    local overview="${N1_HOME}/memory/${ID}/overview.md"
    if [ -f "$overview" ]; then
        n1_write_frontmatter "$overview" "step" "$step_name"
        n1_write_frontmatter "$overview" "current_step" ""
        local display_name
        display_name=$(_n1_step_display_name "$step_name")
        if [ -n "$display_name" ]; then
            # Portable in-place sed via a unique temp (NP-206), then rename
            local tmp; tmp=$(mktemp "${overview}.XXXXXX")
            sed "s/- \[ \] ${display_name}/- [x] ${display_name}/" \
                "$overview" > "$tmp" \
                && mv "$tmp" "$overview" || { rm -f "$tmp"; false; }
        fi
    fi

    # 2. Apply signal scratch file if present
    local sig_file="${N1_HOME}/memory/${ID}/step_signals.tmp"
    if [ -f "$sig_file" ]; then
        local mem_file="${N1_HOME}/memory/${ID}/${step_name}.md"
        if [ -f "$mem_file" ]; then
            local pairs=()
            while IFS= read -r line || [ -n "$line" ]; do
                [ -n "$line" ] && pairs+=("$line")
            done < "$sig_file"
            [ "${#pairs[@]}" -gt 0 ] && n1_write_signals "$mem_file" "${pairs[@]}"
        fi
        rm -f "$sig_file"
    fi

    # 2b. Orca workspace card (N1-224): best-effort; zero subprocesses when ORCA_CLI_COMMAND is unset
    if [ -n "${ORCA_CLI_COMMAND:-}" ] && type n1_orca_sync >/dev/null 2>&1; then
        case "$outcome" in
            escalated|blocked) n1_orca_sync "${step_name}: ${outcome}" --unread ;;
            *)                 n1_orca_sync "${step_name}: ${outcome}" ;;
        esac
    fi

    # 3. Emit telemetry completed_at
    n1_bind_run_to_ticket
    [ -n "${N1_RUN_ID:-}" ] || return 0
    local telem_args=(completed_at=now "outcome=$outcome")
    [ -n "$metadata_json" ] && telem_args+=("metadata=$metadata_json")
    n1_emit_step_event "${N1_RUN_ID}" "${N1_VERSION:-}" "${ID:-}" \
        "$step_name" "$step_number" "${N1_HOME}/memory/${ID}/telemetry" \
        "${telem_args[@]}"
}

# n1_head_record <from_sha>
# N1-184. Records a post-review commit (n1-start SOFT-ONLY pass, n1-pr doc commit, conflict-free
# n1-pr rebase, Codex push:ok) as a step event: step "head", step_number 0, outcome success,
# metadata {"head":"<HEAD>","from":"<from_sha>"}. n1_review_pin set accepts a PR head only at the
# end of an unbroken review -> head chain (n1_review_artifacts_ok in lib/config.sh), so <from_sha>
# must be the head before the commit. No overview.md or checkbox writes (that is why this does not
# use n1_step_end). N1-439: an unset ID is taken from the active-run pointer (the reader resolves
# the ticket the same way). With no active-run ticket and no N1_RUN_ID (standalone n1-pr) it is a
# silent no-op (rc 0; the pin fails open there too). Any other failure prints
# "HEAD_RECORD_FAILED <reason>" on stdout and returns 1, so the calling step sees the lost record.
n1_head_record() {
    local from="${1:-}" to bound ID="${ID:-}"
    bound=$(n1_active_run_ticket 2>/dev/null)
    [ -n "$ID" ] || ID="$bound"
    [[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$ID" != . ] && [ "$ID" != .. ] || ID=""
    if [ -z "$bound" ] && [ -z "${N1_RUN_ID:-}" ]; then
        echo "n1_head_record: no active N1 run; head not recorded (n1_review_pin set fails open too)" >&2
        return 0
    fi
    n1_bind_run_to_ticket
    [ -n "${N1_RUN_ID:-}" ] && [ -n "$ID" ] || { echo "HEAD_RECORD_FAILED unbound (ID=${ID:-<unset>} N1_RUN_ID=${N1_RUN_ID:-<unset>})"; return 1; }
    to=$(git rev-parse HEAD 2>/dev/null) || { echo "HEAD_RECORD_FAILED no-head"; return 1; }
    [[ "$from" =~ ^[0-9a-f]{40}$ && "$to" =~ ^[0-9a-f]{40}$ ]] || { echo "HEAD_RECORD_FAILED bad-sha (from=${from:-<empty>})"; return 1; }
    n1_emit_step_event "${N1_RUN_ID}" "${N1_VERSION:-}" "${ID}" head 0 "${N1_HOME}/memory/${ID}/telemetry" \
        completed_at=now outcome=success "metadata={\"head\":\"$to\",\"from\":\"$from\"}" \
        || { echo "HEAD_RECORD_FAILED emit"; return 1; }
    return 0
}
