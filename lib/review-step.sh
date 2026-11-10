#!/usr/bin/env bash
# lib/review-step.sh (N1-436): deterministic bodies of skills/n1-start/steps/review.md entry and collect blocks.
# Requires lib/preamble.sh first (config.sh, step.sh, validation.sh). Needs $N1_HOME and $ID.
# The step text keeps n1_step_begin/n1_step_end literal (tests/test_step_telemetry.sh, test_review_pin.sh).
_n1_review_step_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_n1_review_step_dir/memory.sh"; source "$_n1_review_step_dir/treestate.sh"
source "$_n1_review_step_dir/related.sh"; source "$_n1_review_step_dir/fingerprints.sh"; source "$_n1_review_step_dir/codex-review.sh"

n1_review_base() {
    # Usage: n1_review_base — prints the review base ref: branch-point file, else origin/<story base>, else
    # config .git.defaultBranch (may be empty); returns 1 on an invalid story base.
    local SB BP_FILE="$N1_HOME/memory/$ID/branch-point"
    SB=$(n1_story_base) || return 1
    [ -f "$BP_FILE" ] && cat "$BP_FILE" || { [ -n "$SB" ] && echo "origin/$SB"; } || n1_config_val '.git.defaultBranch'
    return 0
}

n1_review_preexisting_diff() {
    # Usage: n1_review_preexisting_diff <worktree dir> — N1-275: prints git diff -U0 <base>...HEAD for the pre-existing
    # downgrade check; returns 1 with no output when the base is missing, unresolvable, the diff fails or is empty.
    local base out
    [ -n "$1" ] && [ -d "$1" ] || return 1
    base=$(n1_review_base) && [ -n "$base" ] && git -C "$1" rev-parse --verify -q "$base^{commit}" >/dev/null \
        && out=$(git -C "$1" diff -U0 "$base"...HEAD) && [ -n "$out" ] || return 1
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
    # plus the sanitized review-codex.md at cycle 0 when present (N1-517, SEC-3, optional); records fp-new.tsv fingerprints, persists cycle-0
    # review_c0_blocking (N1-483), checks convergence, prints TQ_MAX=; returns 1 (PARTIAL on stderr) on a missing file.
    local MEM SEC="$1" f FP_FILE CYCLE TQ_MAX C0
    local -a FILES
    MEM="$N1_HOME/memory/$ID"
    CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-0}; [[ $CYCLE =~ ^[0-9]+$ ]] || CYCLE=1
    FILES=(review-hdr.md review-cr.md); [ "$SEC" = true ] && FILES+=(review-sec.md)
    for f in "${FILES[@]}"; do [ -s "$MEM/$f" ] || { echo "PARTIAL: $f missing/empty" >&2; return 1; }; done
    ( cd "$MEM" && cat "${FILES[@]}" ) > "$MEM/review.md"
    [ "$CYCLE" -eq 0 ] && [ -s "$MEM/review-codex.md" ] && n1_review_codex_section "$MEM/review-codex.md" >> "$MEM/review.md"
    FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
    if [ -r "$MEM/fp-new.tsv" ]; then n1_fingerprint_record "$FP_FILE" "$MEM/fp-new.tsv" "$CYCLE" \
        || echo "FP_RECORD_FAILED: see fp-new.tsv.rejected" >&2; fi
    [ "$CYCLE" -gt 0 ] && { n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE" || echo "NON_CONVERGING: cycle $CYCLE"; }
    [ "$CYCLE" -eq 0 ] && C0=$(n1_review_blocking_index_count "$MEM/review-hdr.md") \
        && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" review_c0_blocking "$C0"
    TQ_MAX=$(n1_config_val '.tq.maxFixAttempts'); TQ_MAX=${TQ_MAX:-2}; echo "TQ_MAX=$TQ_MAX"
}

n1_review_codex_start() {
    # Usage: n1_review_codex_start <base ref> — N1-517: at cycle 0 starts scripts/codex-pr-review.sh detached on
    # merge-base(<base ref>, HEAD), the same diff the Claude reviewers see. Prints "codex:started base=<sha>" or
    # "codex:skip reason=<no-id|cycle|covered|autotriage-off|no-base>". A covered or cycle>=1 skip keeps prior Codex files.
    local MEM CYCLE BASE
    local -a L=(nohup)
    [[ "${ID:-}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "codex:skip reason=no-id"; return 0; }
    MEM="$N1_HOME/memory/$ID"
    CYCLE=$(n1_read_frontmatter "$MEM/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-0}
    [ "$CYCLE" = 0 ] || { echo "codex:skip reason=cycle"; return 0; }
    n1_review_codex_covered && { echo "codex:skip reason=covered"; return 0; }
    # An earlier run still inside its deadline (interrupted session) is reused: a second detached run would share its output paths.
    local S0 B0 TO=${N1_CROSS_HOST_REVIEW_TIMEOUT:-900}; TO=${TO%%.*}; [[ $TO =~ ^[0-9]+$ ]] || TO=900
    { read -r S0 B0 < "$MEM/codex-bg.started"; } 2>/dev/null
    if [[ ${S0:-} =~ ^[0-9]+$ && ${B0:-} =~ ^[0-9a-f]{40,64}$ && ! -f "$MEM/codex-bg.done" ]] && [ "$(date +%s)" -lt $(( S0 + TO + 60 )) ] \
       && [ "$B0" = "$(git merge-base "$1" HEAD 2>/dev/null)" ]; then echo "codex:started base=$B0"; return 0; fi
    rm -f "$MEM"/codex-step7* "$MEM/review-codex.md" "$MEM"/codex-bg.*
    [ "$(n1_cross_host_review_val autoTriage)" = true ] || { echo "codex:skip reason=autotriage-off"; return 0; }
    BASE=$(git merge-base "$1" HEAD 2>/dev/null) && [[ $BASE =~ ^[0-9a-f]{40,64}$ ]] || { echo "codex:skip reason=no-base"; return 0; }
    printf '%s %s\n' "$(date +%s)" "$BASE" > "$MEM/codex-bg.started"
    command -v setsid >/dev/null 2>&1 && L=(setsid nohup)   # own session: the review must outlive this shell snippet
    "${L[@]}" bash -c 'bash "$1" "$2" "$3" > "$4/codex-bg.out" 2>&1; echo "$?" > "$4/codex-bg.rc"; mv -f "$4/codex-bg.rc" "$4/codex-bg.done"' \
        _ "$_n1_review_step_dir/../scripts/codex-pr-review.sh" "$BASE" "$ID" "$MEM" </dev/null >/dev/null 2>&1 &
    echo "codex:started base=$BASE"
}

n1_review_codex_collect() {
    # Usage: n1_review_codex_collect — N1-517: waits up to N1_CODEX_COLLECT_WAIT s (default 100: below the host's default 120 s shell-call timeout) per call for the Step 7 run
    # (overall deadline: start + N1_CROSS_HOST_REVIEW_TIMEOUT + 60 s). Prints "codex:base=<sha>" when started, then
    # codex:pending | codex:none outcome=<word> | codex:ran findings:none | codex:ran findings:file=<path>.
    # On ran it writes memory/<ID>/codex-step7 (HEAD), the marker n1_review_codex_covered reads.
    local MEM="$N1_HOME/memory/$ID" START BASE TO DEADLINE WAITED=0 OUT WORD F
    { read -r START BASE < "$MEM/codex-bg.started"; } 2>/dev/null && [[ $START =~ ^[0-9]+$ ]] || { echo "codex:none outcome=not-started"; return 0; }
    echo "codex:base=$BASE"
    TO=${N1_CROSS_HOST_REVIEW_TIMEOUT:-900}; TO=${TO%%.*}; [[ $TO =~ ^[0-9]+$ ]] || TO=900
    DEADLINE=$(( START + TO + 60 ))
    while [ ! -f "$MEM/codex-bg.done" ] && [ "$(date +%s)" -lt "$DEADLINE" ] && [ "$WAITED" -lt "${N1_CODEX_COLLECT_WAIT:-100}" ]; do
        sleep 2; WAITED=$((WAITED + 2))
    done
    if [ ! -f "$MEM/codex-bg.done" ]; then
        if [ "$(date +%s)" -lt "$DEADLINE" ]; then echo "codex:pending"; else echo "codex:none outcome=timeout"; fi
        return 0
    fi
    OUT="$MEM/codex-bg.out"
    WORD=$(sed -n 's/^codex_review_outcome=\([a-z-]*\).*/\1/p' "$OUT" 2>/dev/null | tail -n 1)
    [ "$WORD" = ran ] || { echo "codex:none outcome=${WORD:-unknown}"; return 0; }
    F=$(sed -n 's/^findings:file=//p' "$OUT" | tail -n 1)
    if grep -qx 'findings:none' "$OUT"; then F=""
    elif [[ -n "$F" && "$F" == "$N1_HOME"/scratch/codex-findings-*.md.fenced && "$F" != *..* && -f "$F" ]]; then :
    else echo "codex:none outcome=ran-unavailable"; return 0; fi
    # SEC-1: a findings file stays pending until n1_review_codex_commit sees the validated review-codex.md.
    if [ -n "$F" ]; then git rev-parse HEAD > "$MEM/codex-step7.pending"; echo "codex:ran findings:file=$F"
    else git rev-parse HEAD > "$MEM/codex-step7"; echo "codex:ran findings:none"; fi
}

n1_review_codex_commit() {
    # Usage: n1_review_codex_commit — N1-517 SEC-1: promotes codex-step7.pending to the codex-step7 marker only when
    # review-codex.md exists and opens with the validated header; otherwise drops the pending marker.
    local MEM="$N1_HOME/memory/$ID"
    [ -f "$MEM/codex-step7.pending" ] || return 0
    if [ "$(head -n 1 "$MEM/review-codex.md" 2>/dev/null)" = '## Codex Findings (validated)' ]; then mv -f "$MEM/codex-step7.pending" "$MEM/codex-step7"
    else rm -f "$MEM/codex-step7.pending"; fi
}

n1_review_codex_section() {
    # Usage: n1_review_codex_section <review-codex.md> — N1-517 SEC-3: the Codex block appended to review.md: header, strict
    # Index lines, strict ### [CX-N] headings; every other line is Codex-derived data and is quoted with "> " so it cannot
    # forge an Index line, heading or section.
    [ -f "${1:-}" ] || return 0
    echo '## Codex Findings (validated)'; n1_review_codex_index "$1"
    awk 'NR==1 || /^- \[CX-[0-9]+\] / {next}
        /^### \[CX-[0-9]+\] [^`$]{1,120}$/ || /^[ \t]*$/ {print; next}
        {print "> " $0}' "$1"
}

n1_review_codex_index() {
    # Usage: n1_review_codex_index <review-codex.md> — N1-517: prints only strict [CX-N] Index lines (no backtick, no $,
    # title <= 120); the only Codex-derived text the orchestrator copies into review-hdr.md.
    [ -f "${1:-}" ] || return 0
    grep -E '^- \[CX-[0-9]+\] (Critical|High|Medium|Low) [A-Za-z0-9._/-]+:[0-9]+ — [^`$]{1,120}$' "$1" || true
}

n1_review_fix_scope() {
    # Usage: n1_review_fix_scope <START sha> — N1-517: the N1-405 scope gate for a Step 8 FAIL pass that fixed [CX-N] findings.
    # Allowlist = files of the Step 7 branch diff (codex-bg.started base...START). Prints one push: line; fails closed
    # (kept= writes the codex-gate-blocked marker that every push path refuses on). No head record: Step 7 re-reviews the fix.
    local START="${1:-}" MEM="$N1_HOME/memory/$ID" BASE TIP T OUT
    BASE=$(awk 'NR==1{print $2}' "$MEM/codex-bg.started" 2>/dev/null)
    TIP=$(git rev-parse HEAD)
    T=$(mktemp -d) || T=""
    [[ "${ID:-}" =~ ^[A-Za-z0-9_-]+$ && -n "$T" && $START =~ ^[0-9a-f]{40,64}$ && $BASE =~ ^[0-9a-f]{40,64}$ ]] \
      && git -c core.quotePath=false diff --no-renames --name-only "$BASE...$START" > "$T/allowed.txt" && printf '%s\n' "$START" > "$T/start" \
      || { n1_codex_gate_block "${ID:-}" "$START"; [ -z "$T" ] || rm -rf "$T"; echo "push:blocked paths=gate-unavailable kept=$TIP"; return 0; }
    OUT=$(bash "$_n1_review_step_dir/../scripts/codex-push-gate.sh" "$T/start" "$T/allowed.txt" "$MEM/codex-blocked-fix.patch") || OUT=""
    rm -rf "$T"
    case "$OUT" in push:ok|push:none|push:blocked\ *) ;; *) OUT="push:blocked paths=gate-unavailable";; esac
    if [ "$OUT" = "push:blocked paths=gate-unavailable" ]; then
        if [ "$TIP" = "$START" ]; then OUT="push:none"; elif git reset -q --keep "$START" 2>/dev/null; then OUT="$OUT reset=$TIP"; else OUT="$OUT kept=$TIP"; fi
    fi
    case "$OUT" in *" kept="*) n1_codex_gate_block "$ID" "$START";; esac
    echo "$OUT"
    n1_codex_tree_restore "$ID" || echo "push:blocked paths=uncommitted-edits kept=$TIP"
}
