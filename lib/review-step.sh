#!/usr/bin/env bash
# lib/review-step.sh (N1-436): deterministic bodies of skills/n1-start/steps/review.md entry and collect blocks.
# Requires lib/preamble.sh first (config.sh, step.sh, validation.sh). Needs $N1_HOME and $ID.
# The step text keeps n1_step_begin/n1_step_end literal (tests/test_step_telemetry.sh, test_review_pin.sh).
_n1_review_step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_review_step_dir/memory.sh"; source "$_n1_review_step_dir/treestate.sh"
source "$_n1_review_step_dir/related.sh"; source "$_n1_review_step_dir/fingerprints.sh"

n1_review_base() {
    # Usage: n1_review_base — prints the review base ref: branch-point file, else origin/<story base>, else
    # config .git.defaultBranch (may be empty); returns 1 on an invalid story base.
    local SB BP_FILE="$N1_HOME/memory/$ID/branch-point"
    SB=$(n1_story_base) || return 1
    [ -f "$BP_FILE" ] && cat "$BP_FILE" || { [ -n "$SB" ] && echo "origin/$SB"; } || n1_config_val '.git.defaultBranch'
    return 0
}

n1_review_preexisting_diff() {
    # Usage: n1_review_preexisting_diff (cwd = worktree) — N1-275: prints git diff -U0 <base>...HEAD for the pre-existing
    # downgrade check; returns 1 with no output when the base is missing, unresolvable, the diff fails or is empty.
    local base out
    base=$(n1_review_base) && [ -n "$base" ] && git rev-parse --verify -q "$base^{commit}" >/dev/null \
        && out=$(git diff -U0 "$base"...HEAD) && [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

n1_review_entry() {
    # Usage: n1_review_entry <worktree dir> — prints "BASE_BRANCH= RELATED_ENABLED= CYCLE= INCREMENTAL=", "TREE_BEFORE=",
    # and "FIX_FILES=" when incremental; writes review-spec.md/qa-facts.md; returns 1 on a missing dependency or bad story base.
    local BASE_BRANCH MEM TREE_BEFORE RELATED_ENABLED CYCLE INCREMENTAL FIX_FILES=""
    n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md || { echo "ERROR: implementation.md missing — aborting review step" >&2; return 1; }
    BASE_BRANCH=$(n1_review_base) || { echo "ERROR: invalid story base" >&2; return 1; }
    MEM="$N1_HOME/memory/$ID"; rm -f "$MEM/review-hdr.md" "$MEM/review-cr.md" "$MEM/review-sec.md"
    { echo "# Review Spec (generated)"; n1_extract_sections "$MEM/brainstorm.md" "acceptance criteria" "chosen approach|selected approach|decision"; [ -s "$MEM/brainstorm.md" ] || n1_extract_sections "$MEM/ticket.md" "acceptance criteria" "requirements"; } > "$MEM/review-spec.md"
    { echo "# QA Facts (generated)"; n1_extract_sections "$MEM/qa.md" "evidence" "break-check" "tests run"; [ -n "${BREAK_CHECK_TQ:-}" ] && { echo "## Hollow tests (break-check never-red)"; echo "$BREAK_CHECK_TQ" | sed 's/^/- /'; }; } > "$MEM/qa-facts.md"
    TREE_BEFORE=$(n1_tree_snapshot "$1")
    RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
    CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-0}; [[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1
    INCREMENTAL=false; [ "$CYCLE" -ge 1 ] && [ -s "$N1_HOME/memory/$ID/fix.diff" ] && { INCREMENTAL=true; cp "$N1_HOME/memory/$ID/review.md" "$N1_HOME/memory/$ID/review-prev.md" 2>/dev/null; FIX_FILES=$(cat "$N1_HOME/memory/$ID/fix-changed-files" 2>/dev/null); }
    echo "BASE_BRANCH=$BASE_BRANCH RELATED_ENABLED=$RELATED_ENABLED CYCLE=$CYCLE INCREMENTAL=$INCREMENTAL"
    echo "TREE_BEFORE=$TREE_BEFORE"
    [ "$INCREMENTAL" = true ] && echo "FIX_FILES=$(tr '\n' ' ' <<<"$FIX_FILES")"
    return 0
}

n1_review_collect() {
    # Usage: n1_review_collect <true|false: security-reviewer spawned> — concatenates review-hdr/cr[/sec] into review.md,
    # records fp-new.tsv fingerprints, persists cycle-0 review_c0_blocking (N1-483), checks convergence, prints TQ_MAX=;
    # returns 1 (PARTIAL on stderr) on a missing file.
    local MEM SEC="$1" f FP_FILE CYCLE TQ_MAX C0
    local -a FILES
    MEM="$N1_HOME/memory/$ID"
    FILES=(review-hdr.md review-cr.md); [ "$SEC" = true ] && FILES+=(review-sec.md)
    for f in "${FILES[@]}"; do [ -s "$MEM/$f" ] || { echo "PARTIAL: $f missing/empty" >&2; return 1; }; done
    ( cd "$MEM" && cat "${FILES[@]}" ) > "$MEM/review.md"
    FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"; CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-0}; [[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1
    if [ -r "$MEM/fp-new.tsv" ]; then n1_fingerprint_record "$FP_FILE" "$MEM/fp-new.tsv" "$CYCLE" \
        || echo "FP_RECORD_FAILED: see fp-new.tsv.rejected" >&2; fi
    [ "$CYCLE" -gt 0 ] && { n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE" || echo "NON_CONVERGING: cycle $CYCLE"; }
    [ "$CYCLE" -eq 0 ] && C0=$(n1_review_blocking_index_count "$MEM/review-hdr.md") \
        && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" review_c0_blocking "$C0"
    TQ_MAX=$(n1_config_val '.tq.maxFixAttempts'); TQ_MAX=${TQ_MAX:-2}; echo "TQ_MAX=$TQ_MAX"
}
