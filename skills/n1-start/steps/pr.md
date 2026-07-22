
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
- `docUpdateMode: "autonomous"` — doc updates run without user confirmation in the full pipeline

The PR skill handles documentation update, tech-writer spawning, git push, PR creation, and tracker update.

After PR is created:
- The PR skill reports the URL

**Emit quality outcomes (if telemetry enabled):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
QA_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
REVIEW_FIX=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
QA_FIRST=$( [ "${QA_FIX:-0}" = "0" ] && echo "true" || echo "false" )
REVIEW_FIRST=$( [ "${REVIEW_FIX:-0}" = "0" ] && echo "true" || echo "false" )
FIX_TOTAL=$(( ${QA_FIX:-0} + ${REVIEW_FIX:-0} ))
n1_emit_outcome "$N1_RUN_ID" "$N1_VERSION" "$ID" "${N1_HOME}/memory/$ID/telemetry" \
    "review_pass_first_try=$REVIEW_FIRST" \
    "qa_pass_first_try=$QA_FIRST" \
    "fix_cycles_count=$FIX_TOTAL"
```

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
CI=$(n1_config_val '.ciChecks.enabled')
PR_MODE=$(n1_config_val '.git.prMode')
FW=$(n1_config_val '.finishWork.enabled')
if [ "${CI:-true}" = "true" ] && [ "${PR_MODE}" != "skip" ]; then
    NEXT="ci"
elif [ "${FW:-false}" = "true" ]; then
    NEXT="finish"
else
    NEXT="null"
fi
n1_emit_step_result "pr" "pass" "$NEXT" "null" "" "$N1_HOME/memory/$ID"
```

**CHECKPOINT:** "PR created at <URL>. Ready for Tech Lead review."

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
