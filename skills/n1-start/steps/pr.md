
> **After this step completes, IMMEDIATELY continue to the next pipeline step (FINALIZE MEMORY) — do NOT write a summary message or yield to the user.**

Do not read full reports — n1-pr extracts what it needs via `grep`; tech-writer reads files directly.

Resolve `prMode`: `git.prMode` if present; else `git.draftPR === false` → `"ready"`; else → `"draft"`.

**If `prMode` is `"skip"`**: skip n1-pr/push/`## Pending`; update overview, add ledger row, run telemetry, continue.

**REQUIRED SUB-SKILL:** `n1:n1-pr`. Pass: `docUpdateMode: "autonomous"`.

> **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** do not add post-PR actions inline (CI watch, finish, smoke) — these are separate pipeline steps invoked after this step completes.

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

Update overview: `[x] PR`, set `step: pr`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/fingerprints.sh"
source "$N1_ROOT/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md || { echo "ERROR: implementation.md missing — cannot create PR" >&2; exit 1; }
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
    "review_discarded_count=$DISCARDED"
```

Gate 3 (emitted in FINALIZE MEMORY) carries `PR: <url>` — do not print CHECKPOINT here.

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
