
**If `prMode` was `"skip"` (resolved in Step 10):** Skip to FINALIZE MEMORY — no PR exists to monitor.

Run `n1_config_val '.ciChecks.enabled'` (default: `true`).

> The gate key (`ciChecks.enabled`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `ciChecks.enabled` is `false`:** Skip to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-ci to monitor CI checks and fix failures.

The n1-ci skill receives the PR number from the PR creation step above. It:
1. Polls CI checks until all complete
2. Classifies failures and delegates fixes to the developer agent
3. Loops up to `ciChecks.maxFixAttempts` cycles — the bound and its default are declared in `pipeline.json` `loops[]` (`ci_fix`).
4. Escalates to user only if max attempts exhausted or unknown check below confidence threshold

**After n1-ci returns:**
- If all checks passed (with or without fixes) → continue to FINALIZE
- If user chose "skip" (CI still red) → continue to FINALIZE with CI status noted
- If user is still providing guidance → wait (n1-ci handles the interaction)

> **After `n1:n1-ci` returns, IMMEDIATELY continue to the next pipeline step (finish if enabled, otherwise FINALIZE MEMORY) -- do NOT write a summary message or yield to the user.**

