
> **After this step completes, IMMEDIATELY continue to the next pipeline step (FINALIZE MEMORY) — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

Do not read full reports — n1-pr extracts what it needs via `grep`; tech-writer reads files directly.

Resolve `prMode`: `git.prMode` if present; else `git.draftPR === false` → `"ready"`; else → `"draft"`.

<!-- n1:step-snippet-exception: pre-PR review gate fence runs before the step begins (N1-439) -->
**Pre-PR review gate** (N1-439; skip when `prMode` is `"skip"`): a commit made after Step 7 with no head record (local-test fix, 7b TQ fix, regression fix, "Fix manually", ad-hoc) makes `n1_review_pin set` refuse the PR head, so it is re-reviewed here first.
```bash
source ~/.n1/preamble.sh
MEM="$N1_HOME/memory/$ID"
GATE_ID=$(n1_review_artifacts_ok "$N1_HOME" "$(git rev-parse HEAD)"); GATE_RC=$?
PRE_PR=$(n1_read_frontmatter "$MEM/overview.md" "pre_pr_review_cycle"); [[ "$PRE_PR" =~ ^[0-9]+$ ]] || PRE_PR=0
V=$(grep -m1 '^### Verdict:' "$MEM/review.md" 2>/dev/null); [ -n "$V" ] && [ "$V" != '### Verdict: PASS' ] && GATE_RC=2
if [ "$GATE_RC" = 1 ] || [ "$GATE_RC" = 3 ]; then
    n1_increment_counter "$MEM/overview.md" "pre_pr_review_cycle" >/dev/null
    REVIEWED=""; [ "$GATE_RC" = 3 ] && REVIEWED=$(n1_review_reviewed_head "$N1_HOME")
    { [ -n "$REVIEWED" ] && git diff "$REVIEWED" HEAD > "$MEM/fix.diff" && git diff --name-only "$REVIEWED" HEAD > "$MEM/fix-changed-files"; } || : > "$MEM/fix.diff"
fi
echo "PRE_PR_GATE=$GATE_RC $GATE_ID PRE_PR_REVIEW_CYCLE=$PRE_PR/3"
```
- `PRE_PR_GATE=0` or `2`: continue (`2`: review.md verdict not PASS, e.g. Step 8 **Exhausted**; a re-review must not clear open findings, so n1-pr's pin refusal is the intended stop).
- `1` (no review step ran or its artifacts are missing; the fence empties `fix.diff` so the review runs at full scope): count it like `3` (same cap, same cap handling below); do not invoke n1-pr; run Step 7, then Step 8 when the verdict routes there, then this step again. Do not re-run Step 9 (local testing already ran for this diff; its bounded loop and `local_test_fix_cycle` persist, and re-entering it after exhaustion would re-escalate).
- `3` (HEAD is past the review head chain; the fence wrote `fix.diff` from the last reviewed head, empty when unknown): `PRE_PR_REVIEW_CYCLE` below 3 → return to Step 7 (`review_fix_cycle` ≥ 1 reviews `fix.diff` incrementally, else full scope); Step 8 follows when the verdict routes there (Step 9 is not re-run), then this step again. At 3 (for `1` or `3`) → § Autonomy Gate (qualityEscalations) with step=`pr`, action=`proceed to PR unreviewed`, ledger_context=`HEAD not at the review chain end; pre-PR re-review cap reached`; on that action add `- [UNREVIEWED-HEAD] High — commits after the last review were not re-reviewed` under `## For Human Review` in review.md (file-write) and continue (n1-pr refuses the pin; a human reviews before merge). Prompt otherwise: 1. Proceed to PR unreviewed (Recommended: the cap is reached, the same choice fix.md **Exhausted** recommends) 2. Re-review once more (return to Step 7). **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

```bash
source ~/.n1/preamble.sh
n1_step_begin "pr" 12
FIX_AUDIT=$(n1_review_fix_audit "$N1_HOME/memory/$ID/overview.md") || true; echo "FIX_AUDIT=$FIX_AUDIT"
```

`FIX_AUDIT` other than `ok`, including empty (review fix cap bypassed): before n1-pr, ensure review.md lists `- [FIX-CAP] High — review_fix_cycle past the cap without an [asked] ledger row` under `## For Human Review` (file-write; create the section if absent) so the PR body shows it; never an `[auto]` pass.

**If `prMode` is `"skip"`**: skip n1-pr/push/`## Pending`; add ledger row, run the last block below (end `skipped`), continue.

**REQUIRED SUB-SKILL:** `n1:n1-pr`. Pass: `docUpdateMode: "autonomous"`.

> **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** do not add post-PR actions inline (CI watch, finish, smoke) — these are separate pipeline steps invoked after this step completes.

**Post-condition (skip when `prMode` is `"skip"`):** every open PR on this branch must have a Codex receipt (n1-pr step 1 or 3); a hand-written `gh pr create` does not count.
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
MISSING=$(n1_review_check_run)
[ -z "$MISSING" ] || { echo "ERROR: n1-pr Codex step not run for: $MISSING" >&2; exit 1; }
```
On exit 1, do not continue: run n1-pr step 3 (`skills/n1-pr/steps/03-codex-review.md`) once per branch, then re-run this check.

After PR created: record `## Pending` section in `$N1_HOME/memory/$ID/overview.md` (idempotent upsert):
```markdown
## Pending
awaiting: merge
pr: <PR number>
pr_url: <PR URL>
branch: <branch name>
last_checked: <date -u +%Y-%m-%dT%H:%M:%SZ>
created: <same timestamp>
```

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/fingerprints.sh"
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md || { n1_step_end "pr" 12 failed; echo "ERROR: implementation.md missing — cannot create PR" >&2; exit 1; }
QA_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
REVIEW_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
QA_FIRST=$( [ "${QA_FIX:-0}" = "0" ] && echo "true" || echo "false" )
REVIEW_FIRST=$( [ "${REVIEW_FIX:-0}" = "0" ] && echo "true" || echo "false" )
FIX_TOTAL=$(( ${QA_FIX:-0} + ${REVIEW_FIX:-0} ))
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
BLOCKING_C1=$(n1_fingerprint_blocking_count_for_cycle "$FP_FILE" 0 2>/dev/null || echo 0)
BC_VERDICT=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "break_check_verdict"); BC_VERDICT=${BC_VERDICT:-skipped}
DISCARDED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_discarded_count"); DISCARDED=${DISCARDED:-0}
n1_emit_outcome "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" \
    "review_pass_first_try=$REVIEW_FIRST" \
    "qa_pass_first_try=$QA_FIRST" \
    "fix_cycles_count=$FIX_TOTAL" \
    "review_blocking_count=$BLOCKING_C1" \
    "review_fix_cycles=${REVIEW_FIX:-0}" \
    "qa_fix_cycles=${QA_FIX:-0}" \
    "break_check_verdict=$BC_VERDICT" \
    "review_discarded_count=$DISCARDED" \
    "review_unresolved_at_pr=$(grep -qs '^## For Human Review' "$N1_HOME/memory/$ID/review.md" && echo true || echo false)"
n1_step_end "pr" 12 "<success|skipped>"
```

Gate 3 (emitted in FINALIZE MEMORY) carries `PR: <url>` — do not print CHECKPOINT here.

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
