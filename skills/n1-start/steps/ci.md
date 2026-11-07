
```bash
source ~/.n1/preamble.sh
n1_step_begin "ci" 13
```

**If `prMode` is `"skip"`**: no PR; skip ci gate/n1-ci; run the end block with `skipped`; continue.

**REQUIRED SUB-SKILL:** Use n1:n1-ci to monitor CI checks and fix failures. Pass it the PR number from the PR creation step above.

**After n1-ci returns:**
- If all checks passed (with or without fixes) → end block with `success` (no checks configured: `skipped`), then continue to FINALIZE
- If user chose "skip" (CI still red) → end block with `failed`, continue to FINALIZE with CI status noted
- If user is still providing guidance → wait (n1-ci handles the interaction)

```bash
source ~/.n1/preamble.sh
n1_step_end "ci" 13 "<success|failed|skipped>"
```

> **After `n1:n1-ci` returns, IMMEDIATELY continue to the next pipeline step (finish if enabled, otherwise FINALIZE MEMORY) -- do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**
