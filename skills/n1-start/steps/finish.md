
**Finish gate.** `n1_merge_allowed` decides: only queue children with `queue.mergeOnFinish: true` chain into n1-finish.

```bash
source ~/.n1/preamble.sh
if n1_merge_allowed; then GATE_ENABLED=true; else GATE_ENABLED=false; fi
n1_record_decision finish-gate "$GATE_ENABLED" '{"config":"n1_merge_allowed"}' "enabled=${GATE_ENABLED}"
echo "finish-gate:${GATE_ENABLED}"
```

**If `finish-gate:false`:** tell the user "Merge the PR, then run `/n1:n1-finish <ID>`." (with `prMode: "skip"`: "Run `/n1:n1-finish <ID>` to merge locally."), then continue to FINALIZE MEMORY.

**If `finish-gate:true`:** invoke skill `n1:n1-finish` to merge, deploy, close the ticket.

> **After n1-finish returns, continue to FINALIZE MEMORY — no summary, no yield.**
