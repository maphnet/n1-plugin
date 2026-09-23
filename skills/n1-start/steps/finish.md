
**If `N1_STOP_AT` is `ci`** (set by the queue runner): skip to FINALIZE MEMORY. The queue never merges.

Run `n1_config_val '.finishWork.enabled'` (default: `false`).

```bash
source ~/.n1/preamble.sh
GATE_ENABLED=$(n1_config_val '.finishWork.enabled' 2>/dev/null || echo 'false')
n1_record_decision finish-gate "$( [ "${GATE_ENABLED:-false}" = "true" ] && echo true || echo false )" '{"config":"finishWork.enabled"}' "enabled=${GATE_ENABLED:-false}"
```

> Gate key matches `pipeline.json` `gates[]`.

**If `false`:** skip to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/merge, deploy, close ticket.

> **After n1-finish returns, continue to FINALIZE MEMORY — no summary, no yield.**
