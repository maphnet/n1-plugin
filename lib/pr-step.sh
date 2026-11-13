#!/usr/bin/env bash
# lib/pr-step.sh (N1-476): deterministic bodies of skills/n1-start/steps/pr.md gate, entry and outcome blocks.
# Requires lib/preamble.sh first. Needs $N1_HOME and $ID. Never calls n1_step_begin/n1_step_end (pr.md keeps them; the
# pr-worker denies them). Holds no remote-write commands (branch push, PR create, merge, tracker API calls): the hook text-scan must see those in skill text.
# (Do not spell those commands out in this comment: tests/test_pr_step_lib.sh greps lib/*-step.sh for them.)
_n1_pr_step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_pr_step_dir/fingerprints.sh"

n1_pr_mode() {
    # Usage: n1_pr_mode — prints git.prMode if present (incl. skip); else ready when git.draftPR is false; else draft.
    local P; P=$(n1_config_val '.git.prMode')
    [ -n "$P" ] || { [ "$(n1_config_val '.git.draftPR')" = false ] && P=ready || P=draft; }
    echo "$P"
}

n1_pr_gate() {
    # Usage: n1_pr_gate — pre-PR review gate (N1-439). Prints PRE_PR_GATE=<rc> <id> PRE_PR_REVIEW_CYCLE=<n>/3; on rc 1 or 3
    # bumps pre_pr_review_cycle and writes fix.diff/fix-changed-files from the last reviewed head (empty fix.diff when unknown).
    local MEM="$N1_HOME/memory/$ID" GATE_ID GATE_RC PRE_PR V REVIEWED
    [ "$(n1_pr_mode)" = skip ] && { echo "PRE_PR_GATE=0"; return 0; }
    GATE_ID=$(n1_review_artifacts_ok "$N1_HOME" "$(git rev-parse HEAD)"); GATE_RC=$?
    PRE_PR=$(n1_read_frontmatter "$MEM/overview.md" "pre_pr_review_cycle"); [[ "$PRE_PR" =~ ^[0-9]+$ ]] || PRE_PR=0
    V=$(grep -m1 '^### Verdict:' "$MEM/review.md" 2>/dev/null); [ -n "$V" ] && [ "$V" != '### Verdict: PASS' ] && GATE_RC=2
    if [ "$GATE_RC" = 1 ] || [ "$GATE_RC" = 3 ]; then
        n1_increment_counter "$MEM/overview.md" "pre_pr_review_cycle" >/dev/null
        REVIEWED=""; [ "$GATE_RC" = 3 ] && REVIEWED=$(n1_review_reviewed_head "$N1_HOME")
        { [ -n "$REVIEWED" ] && git diff "$REVIEWED" HEAD > "$MEM/fix.diff" && git diff --name-only "$REVIEWED" HEAD > "$MEM/fix-changed-files"; } || : > "$MEM/fix.diff"
    fi
    echo "PRE_PR_GATE=$GATE_RC $GATE_ID PRE_PR_REVIEW_CYCLE=$PRE_PR/3"
}

n1_pr_entry() {
    # Usage: n1_pr_entry — prints FIX_AUDIT=, prMode=, route:worker (clean tree) or route:inline, and the pr-worker model line;
    # removes stale pr-result.md and pr-report.md.
    local FIX_AUDIT PM
    FIX_AUDIT=$(n1_review_fix_audit "$N1_HOME/memory/$ID/overview.md") || true; echo "FIX_AUDIT=$FIX_AUDIT"
    echo "prMode=$(n1_pr_mode)"
    rm -f "$N1_HOME/memory/$ID/pr-result.md" "$N1_HOME/memory/$ID/pr-report.md"; [ -z "$(git status --porcelain)" ] && echo route:worker || echo route:inline
    IFS=$'\t' read -r PM _ < <(n1_resolve_agent pr-worker); echo "model:$PM memory:$N1_HOME/memory/$ID n1_root:$N1_ROOT worktree:$(git rev-parse --show-toplevel)"
}

n1_pr_outcome() {
    # Usage: n1_pr_outcome — emits the run outcome record (n1_emit_outcome); rc 1 with an error when implementation.md is missing.
    local QA_FIX REVIEW_FIX QA_FIRST REVIEW_FIRST FIX_TOTAL FP_FILE C0 HARD_FIRST="" BLOCKING_C1 BC_VERDICT DISCARDED
    n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md || { echo "ERROR: implementation.md missing — cannot create PR" >&2; return 1; }
    QA_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
    REVIEW_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
    QA_FIRST=$( [ "${QA_FIX:-0}" = "0" ] && echo "true" || echo "false" )
    REVIEW_FIRST=$( [ "${REVIEW_FIX:-0}" = "0" ] && echo "true" || echo "false" )
    FIX_TOTAL=$(( ${QA_FIX:-0} + ${REVIEW_FIX:-0} ))
    FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
    C0=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_c0_blocking")
    if [[ $C0 =~ ^[0-9]+$ ]]; then BLOCKING_C1=$C0; HARD_FIRST=$([ "$C0" = 0 ] && echo true || echo false); else BLOCKING_C1=$(n1_fingerprint_blocking_count_for_cycle "$FP_FILE" 0 2>/dev/null || echo 0); fi
    BC_VERDICT=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "break_check_verdict"); BC_VERDICT=${BC_VERDICT:-skipped}
    DISCARDED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_discarded_count"); DISCARDED=${DISCARDED:-0}
    n1_emit_outcome "${N1_RUN_ID:-}" "${N1_VERSION:-}" "$ID" "${N1_HOME}/memory/$ID/telemetry" \
        "review_pass_first_try=$REVIEW_FIRST" \
        "review_pass_first_try_hard=$HARD_FIRST" \
        "qa_pass_first_try=$QA_FIRST" \
        "fix_cycles_count=$FIX_TOTAL" \
        "review_blocking_count=$BLOCKING_C1" \
        "review_fix_cycles=${REVIEW_FIX:-0}" \
        "qa_fix_cycles=${QA_FIX:-0}" \
        "break_check_verdict=$BC_VERDICT" \
        "review_discarded_count=$DISCARDED" \
        "review_unresolved_at_pr=$(grep -qs '^## For Human Review' "$N1_HOME/memory/$ID/review.md" && echo true || echo false)"
    return 0
}
