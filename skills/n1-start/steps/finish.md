
**Finish gate.** `n1_finish_enabled` decides.

```bash
source ~/.n1/preamble.sh
if n1_finish_enabled; then GATE_ENABLED=true; else GATE_ENABLED=false; fi
n1_record_decision finish-gate "$GATE_ENABLED" '{"config":"n1_finish_enabled"}' "enabled=${GATE_ENABLED}"
echo "finish-gate:${GATE_ENABLED}"
```

> Queue: `queue.mergeOnFinish` (a hook also blocks its merge commands). Interactive: `finishWork.enabled`.

**If `finish-gate:false`:** skip to FINALIZE MEMORY.

`prMode: "skip"` uses the local-merge path.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/merge, deploy, close ticket.

> **After n1-finish returns, continue to FINALIZE MEMORY — no summary, no yield.**
