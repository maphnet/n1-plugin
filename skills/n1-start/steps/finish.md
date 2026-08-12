
**If `git.prMode` was `"skip"`:** the finish step still runs — n1-finish handles the local-merge path (no PR).

Run `n1_config_val '.finishWork.enabled'` (default: `false`).

> The gate key (`finishWork.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `finishWork.enabled` is `false`:**
- Full pipeline mode: skip silently to FINALIZE MEMORY.
- Step mode: emit `outcome: "skip"` with `next_step: null` and stop.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/perform the merge, watch the deployment, and close the ticket.

**Outcome mapping (step mode):**
- Merged (+ deploy ok or not watched) + ticket handled → `outcome: "pass"`, `next_step: null`
- Gate closed → `outcome: "skip"`, `next_step: null`
- PR closed unmerged, CI red, merge blocked, or deploy failed → `outcome: "fail"`, `next_step: null`
- Merge-wait timeout or deploy-watch timeout → n1-finish writes `escalation/request.json` AND emits the step result itself (`outcome: "escalation"`, `next_step: null`) — the orchestrator must NOT emit a duplicate result for this case

> **After `n1:n1-finish` returns, IMMEDIATELY continue to FINALIZE MEMORY with the finish result noted -- do NOT write a summary message or yield to the user.**

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "finish" "pass" "null" "null" "" "$N1_HOME/memory/$ID"
```
