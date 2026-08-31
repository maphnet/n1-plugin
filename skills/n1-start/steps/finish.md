
**If `git.prMode` was `"skip"`:** the finish step still runs — n1-finish handles the local-merge path (no PR).

Run `n1_config_val '.finishWork.enabled'` (default: `false`).

> The gate key (`finishWork.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `finishWork.enabled` is `false`:** skip silently to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/perform the merge, watch the deployment, and close the ticket.

> **After `n1:n1-finish` returns, IMMEDIATELY continue to FINALIZE MEMORY with the finish result noted -- do NOT write a summary message or yield to the user.**
