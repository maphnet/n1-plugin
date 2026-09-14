#!/usr/bin/env bash
# N1 per-step choreography helpers
#
# n1_step_begin <step_name> <step_number>
#   Emits telemetry started_at. No-op when N1_RUN_ID is absent.
#
# n1_step_end <step_name> <step_number> <outcome> [metadata_json]
#   1. Writes step: <step_name> to overview.md frontmatter
#   2. Ticks the progress checkbox for this step in overview.md
#   3. Reads $N1_HOME/memory/$ID/step_signals.tmp if present,
#      calls n1_write_signals against $N1_HOME/memory/$ID/<step_name>.md,
#      then deletes the tmp file.
#   4. Emits telemetry completed_at with outcome (and optional metadata JSON).
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
        estimation)                printf '%s' "Estimation" ;;
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
    local step_name="$1" step_number="$2"
    [ -n "${N1_RUN_ID:-}" ] || return 0   # no-op if run context absent
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
        local display_name
        display_name=$(_n1_step_display_name "$step_name")
        if [ -n "$display_name" ]; then
            # Portable in-place sed: write to tmp then rename
            sed "s/- \[ \] ${display_name}/- [x] ${display_name}/" \
                "$overview" > "${overview}.step.tmp" \
                && mv "${overview}.step.tmp" "$overview"
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

    # 3. Emit telemetry completed_at
    [ -n "${N1_RUN_ID:-}" ] || return 0
    local telem_args=(completed_at=now "outcome=$outcome")
    [ -n "$metadata_json" ] && telem_args+=("metadata=$metadata_json")
    n1_emit_step_event "${N1_RUN_ID}" "${N1_VERSION:-}" "${ID:-}" \
        "$step_name" "$step_number" "${N1_HOME}/memory/${ID}/telemetry" \
        "${telem_args[@]}"
}
