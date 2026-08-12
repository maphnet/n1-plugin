
**If `prMode` was `"skip"` (resolved in Step 10):** Skip to FINALIZE MEMORY — no PR exists to monitor.

Run `n1_config_val '.ciChecks.enabled'` (default: `true`).

> The gate key (`ciChecks.enabled`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `ciChecks.enabled` is `false`:** Skip to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-ci to monitor CI checks and fix failures.

**After n1-ci returns:**
- If all checks passed (with or without fixes) → continue to FINALIZE
- If user chose "skip" (CI still red) → continue to FINALIZE with CI status noted
- If user is still providing guidance → wait (n1-ci handles the interaction)

> **After `n1:n1-ci` returns, IMMEDIATELY continue to the next pipeline step (finish if enabled, otherwise FINALIZE MEMORY) -- do NOT write a summary message or yield to the user.**

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
FW=$(n1_config_val '.finishWork.enabled')
if [ "${FW:-false}" = "true" ]; then
    NEXT="finish"
else
    NEXT="null"
fi
n1_emit_step_result "ci" "pass" "$NEXT" "null" "" "$N1_HOME/memory/$ID"
```
