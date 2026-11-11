#!/usr/bin/env bash
# lib/qa-step.sh (N1-476): deterministic bodies of skills/n1-start/steps/qa.md post-agent blocks.
# Requires lib/preamble.sh first. Needs $N1_HOME and $ID. Never calls n1_step_begin/n1_step_end (qa.md keeps them).
# Input: the qa-engineer return, written by the model to $N1_HOME/memory/$ID/qa-return.md with the file-write mechanism.
_n1_qa_step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_qa_step_dir/memory.sh"; source "$_n1_qa_step_dir/breakcheck.sh"

n1_qa_verify() {
    # Usage: n1_qa_verify — writes the return's n1:signals to qa.md, marks QA degraded when qa.md has no ### Evidence,
    # re-runs the named tests in an isolated shell (env -i), prints NEW_FUNC_UNTESTED= and QA_DEGRADED=.
    local QD="$N1_HOME/memory/$ID" RET="" SIGNAL_LINE="" PAIRS NEW_FUNC_UNTESTED="" QA_DEGRADED=0
    local VCMDS VERIFY_LOG ACTUAL_EXIT REPORTED_EXIT RUNNER_CMD
    rm -f "$QD/qa-verify.log"
    [ -f "$QD/qa-return.md" ] && { RET=$(cat "$QD/qa-return.md"); rm -f "$QD/qa-return.md"; }  # consumed: a later qa loop cycle must not reuse stale signals
    SIGNAL_LINE=$(grep -m1 '^n1:signals ' <<<"$RET")
    # shellcheck disable=SC2086 # PAIRS splits into key=value words on purpose
    [ -n "$SIGNAL_LINE" ] && { PAIRS=$(sed 's/^n1:signals //' <<<"$SIGNAL_LINE"); n1_write_signals "$QD/qa.md" $PAIRS; }
    NEW_FUNC_UNTESTED=$(grep -o 'new_functionality_untested=[^ ]*' <<<"$SIGNAL_LINE" | cut -d= -f2)
    if ! grep -q "^### Evidence" "$QD/qa.md" 2>/dev/null; then
        QA_DEGRADED=1; n1_write_frontmatter "$QD/overview.md" "qa_verdict_unverified" "true"
        n1_append_key_decision "$QD/overview.md" "QA degraded: unevidenced verdict"
    fi
    VCMDS=$(grep -E '^(New|Regression|Fixed) test:' "$QD/qa.md" 2>/dev/null | while IFS= read -r l; do n1_break_check_parse_line "$l" cmd 2>/dev/null; done | grep .)
    if [ -z "$VCMDS" ]; then n1_append_key_decision "$QD/overview.md" "QA verifyGate skipped: no named tests in qa.md"
    else
        VERIFY_LOG="$QD/qa-verify.log"; ACTUAL_EXIT=0
        while IFS= read -r RUNNER_CMD; do env -i HOME="$HOME" PATH="$PATH" bash -c "$RUNNER_CMD" < /dev/null || ACTUAL_EXIT=1; done <<< "$VCMDS" > "$VERIFY_LOG" 2>&1
        REPORTED_EXIT=$(grep -m1 "^Exit code:" "$QD/qa.md" | grep -o '[0-9]*' | head -1)
        [ "${REPORTED_EXIT:-0}" = 0 ] && [ "$ACTUAL_EXIT" != 0 ] && { n1_append_key_decision "$QD/overview.md" "QA verifyGate mismatch: reported 0/none, named test failed. Log: $VERIFY_LOG"; n1_write_frontmatter "$QD/overview.md" "qa_verdict_unverified" "true"; QA_DEGRADED=1; }
    fi
    echo "NEW_FUNC_UNTESTED=$NEW_FUNC_UNTESTED"
    echo "QA_DEGRADED=$QA_DEGRADED"
}

n1_qa_break_check() {
    # Usage: n1_qa_break_check <worktree dir> — reverts the change under the qa.md Regression/New test lines (n1_break_check),
    # writes break_check_verdict frontmatter, prints BC_VERDICT=, BC_MODE=, BC_MSG= (when set) and the TQ list between
    # BREAK_CHECK_TQ<< and BREAK_CHECK_TQ>>. rc 1 on an invalid story base.
    local WT="$1" QD="$N1_HOME/memory/$ID" BC_MODE BC_MAX TASK_TYPE SB BC_DEF BC_BASE BC_LOG BREAK_CHECK_TQ="" BC_VERDICT="skipped"
    local REG_LINE REG_NAME REG_CMD BC_V BC_JSON BC_MSG line N C
    BC_MODE=$(n1_config_val '.qa.breakCheck'); BC_MODE=${BC_MODE:-bugs}; BC_MAX=$(n1_config_val '.qa.breakCheckMaxTests'); BC_MAX=${BC_MAX:-5}
    TASK_TYPE=$(n1_read_signal "$QD/ticket.md" "task_type")
    SB=$(n1_story_base) || { echo "ERROR: invalid story base" >&2; return 1; }
    BC_DEF=$(n1_config_val '.git.defaultBranch'); BC_BASE=$(n1_break_check_base "$QD/branch-point" "${SB:-${BC_DEF:-main}}" "$WT")
    BC_LOG="$QD/break-check.log"
    REG_LINE=$(grep -m1 '^Regression test:' "$QD/qa.md" 2>/dev/null || true)
    REG_NAME=$(n1_break_check_parse_line "$REG_LINE" name); REG_CMD=$(n1_break_check_parse_line "$REG_LINE" cmd)
    if [ -z "$REG_NAME" ] || [ -z "$REG_CMD" ]; then BC_V=inconclusive; [ -n "$TASK_TYPE" ] && [ "$TASK_TYPE" != bug ] && [ "$BC_MODE" = bugs ] && BC_V=skipped
        BC_JSON="{\"success\":false,\"error\":{\"kind\":\"$BC_V\",\"message\":\"qa.md has no Regression test: line\"},\"verdict\":\"$BC_V\"}"
    else BC_JSON=$(n1_break_check "$BC_BASE" "$REG_CMD" "$REG_NAME" "$BC_LOG" "$WT" || true); fi
    BC_VERDICT=$(echo "$BC_JSON" | jq -r '.verdict // "inconclusive"'); BC_MSG=$(echo "$BC_JSON" | jq -r '.error.message // empty')
    grep '^New test:' "$QD/qa.md" 2>/dev/null | head -n "$BC_MAX" | while IFS= read -r line; do
        N=$(n1_break_check_parse_line "$line" name); C=$(n1_break_check_parse_line "$line" cmd)
        printf '%s\t%s\n' "$N" "$(n1_break_check "$BC_BASE" "$C" "$N" "$BC_LOG.${N//[^[:alnum:]._-]/_}" "$WT" 2>/dev/null | jq -r '.verdict // "inconclusive"')"
    done > "$QD/break-check.new-tests"
    BREAK_CHECK_TQ=$(awk -F'\t' '$2 !~ /^(red-then-green|no-diff)$/ {print $1" ("$2")"}' "$QD/break-check.new-tests")
    n1_write_frontmatter "$QD/overview.md" "break_check_verdict" "$BC_VERDICT"
    echo "BC_VERDICT=$BC_VERDICT"; echo "BC_MODE=$BC_MODE"
    [ -n "$BC_MSG" ] && echo "BC_MSG=$BC_MSG"
    printf 'BREAK_CHECK_TQ<<\n%s\nBREAK_CHECK_TQ>>\n' "$BREAK_CHECK_TQ"
    return 0
}
