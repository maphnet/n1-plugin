
**Context discipline — resolve `prMode` (below) BEFORE opening any memory file:**
- `skip` mode reads overview.md only. Do NOT read `review.md`, `qa.md`, `implementation.md`, or `local-testing.md` — the skip path needs only a checkbox update and a report line.
- `draft`/`ready` mode: do not read full reports in this session either — n1-pr extracts the verdict lines it needs via `grep`, and the tech-writer reads the full files itself via the paths it receives.

Resolve `prMode` from `$N1_HOME/config.json` using the fallback chain:
1. If `git.prMode` is present → use it (`"draft"`, `"ready"`, or `"skip"`)
2. Else if `git.draftPR` is `false` → treat as `"ready"`
3. Otherwise → treat as `"draft"`

**If `prMode` is `"skip"`:**
- Do NOT invoke n1-pr
- Do NOT push the branch
- Update `overview.md`: check `[x] PR`, set `step: pr`, add key decision: `"PR: skipped (prMode: skip)"`
- Report: "PR step skipped. Branch `<branch-name>` is ready — merge manually when done."
- Skip Step 11 (CI watch) — no PR to monitor
- Proceed to FINALIZE MEMORY

**Otherwise:** invoke n1-pr as below.

**REQUIRED SUB-SKILL:** Use n1:n1-pr to create the pull request.

Pass to n1-pr:
- `docUpdateMode: "autonomous"` — doc updates run without user confirmation in the pipeline

After PR is created:
- The PR skill reports the URL
- **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** any later user request to change the branch is handled per n1-pr `## Step 8: Post-PR Follow-ups` (developer agent in fix mode) — the orchestrator never edits or commits project files itself.

**Record pending-merge state** (enables cross-session finish resume; skip when `prMode` is `skip`):

Append (or replace, idempotent upsert) a `## Pending` section in `$N1_HOME/memory/$ID/overview.md`:

```markdown
## Pending
awaiting: merge
pr: <PR number>
pr_url: <PR URL>
branch: <branch name>
last_checked: <output of `date -u +%Y-%m-%dT%H:%M:%SZ`>
created: <same timestamp>
```

Update overview: `[x] PR`, set `step: pr`

**Emit quality outcomes (if telemetry enabled):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/fingerprints.sh"
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

**CHECKPOINT:** "PR created at <URL>. Ready for Tech Lead review."

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
