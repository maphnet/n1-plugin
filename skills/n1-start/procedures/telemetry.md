# Procedure: Telemetry

Read `telemetry.enabled` from `$N1_HOME/config.json` (default `false`).

**If `true`:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_VERSION=$(n1_plugin_version)
N1_RUN_ID=$(date -u +n1-run-%Y%m%dT%H%M%SZ)
mkdir -p "${N1_HOME}/memory/$ID/telemetry/raw/steps" "${N1_HOME}/memory/$ID/telemetry/raw/agents" "${N1_HOME}/memory/$ID/telemetry/runs"
echo '{"run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'"}' > "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

**If `false`:** skip all telemetry shell calls. Do not generate `N1_RUN_ID`.

**Step markers:** before agents emit started_at=now; after overview update emit completed_at, outcome, loop, metadata; skipped uses outcome=skip. Use each step's documented metadata (analysis/implementation/review include cross-repo fields).
