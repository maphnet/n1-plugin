
**Finish gate.** One helper decides. Do not read `finishWork.*` or the queue's stop-at signal yourself.

```bash
source ~/.n1/preamble.sh
if n1_finish_enabled; then GATE_ENABLED=true; else GATE_ENABLED=false; fi
n1_record_decision finish-gate "$GATE_ENABLED" '{"config":"n1_finish_enabled"}' "enabled=${GATE_ENABLED}"
echo "finish-gate:${GATE_ENABLED}"
```

> Gate key matches `pipeline.json` `gates[]`. `n1_finish_enabled`: queue children (`N1_QUEUE_RUN_ID` set) continue only when `queue.mergeOnFinish` is `true`. Interactive runs follow `finishWork.enabled`. A PreToolUse hook denies merge commands in queue children regardless of this step.

**If `finish-gate:false`:** skip to FINALIZE MEMORY.

With `prMode: "skip"`, n1-finish takes the local-merge path.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/merge, deploy, close ticket.

> **After n1-finish returns, continue to FINALIZE MEMORY — no summary, no yield.**
