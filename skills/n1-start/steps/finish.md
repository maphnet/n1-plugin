
Run `n1_config_val '.finishWork.enabled'` (default: `false`).

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/telemetry.sh"
GATE_ENABLED=$(n1_config_val '.finishWork.enabled' 2>/dev/null || echo 'false')
n1_record_decision finish-gate "$( [ "${GATE_ENABLED:-false}" = "true" ] && echo true || echo false )" '{"config":"finishWork.enabled"}' "enabled=${GATE_ENABLED:-false}"
```

> The gate key (`finishWork.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `finishWork.enabled` is `false`:** skip silently to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-finish to verify/perform the merge, watch the deployment, and close the ticket.

> **After `n1:n1-finish` returns, IMMEDIATELY continue to FINALIZE MEMORY with the finish result noted -- do NOT write a summary message or yield to the user.**
