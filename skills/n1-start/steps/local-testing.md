
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

Run `n1_config_val '.localTesting.enabled'` (default: `true`).

```bash
source ~/.n1/preamble.sh
n1_step_begin "local-testing" 11
GATE_ENABLED=$(n1_config_val '.localTesting.enabled' 2>/dev/null || echo 'true')
n1_record_decision local-testing-gate "$( [ "${GATE_ENABLED:-true}" = "true" ] && echo true || echo false )" '{"config":"localTesting.enabled"}' "enabled=${GATE_ENABLED:-true}"
[ "${GATE_ENABLED:-true}" = "true" ] || n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"disabled"}'
echo "LOCAL_TESTING_MODE=$(n1_resolve_local_testing_mode "$(git rev-parse --show-toplevel)")"
```

> The gate key (`localTesting.enabled`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `localTesting.enabled` is `false`:** Skip to Step 10 (PR CREATION).

**Mode resolution:** `LOCAL_TESTING_MODE` was resolved above via `n1_resolve_local_testing_mode`. Precedence (in `lib/config.sh`): explicit `localTesting.mode` > `localTesting.autoLive: true` plus a root compose file (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`) -> `"live"` > non-empty `localTesting.startCommand` -> `"live"` > `"test"`.

Capture the resolved mode as `LOCAL_TESTING_MODE` for use throughout this step.

**If mode is `"smoke"`:** Skip local testing entirely. Key decision: "Local Testing: skipped -- post-deploy verification follows its separate configuration". End the step:
```bash
source ~/.n1/preamble.sh
n1_step_end "local-testing" 11 skipped '{"action_type":"smoke_deferred","skip_reason":"smoke_mode"}'
```
Skip to Step 10 (PR CREATION).

> **ORCHESTRATOR GUARDRAIL (local testing): do not run test suites, `pytest`/`make test`/`npm test`, coverage runs, package installs (`pip`, `uv`, `npm`), interpreter/venv discovery or repair, or app/infrastructure startup in this step. All execution belongs to the developer spawn in 9c. If the environment is broken, the developer reports it and it is routed through the `local_test_env_failure` escalation — the orchestrator never debugs it inline. The only permitted orchestrator commands here are the memory/config helpers, `git diff --name-only` and `n1_classify_local_test_skip` for the auto-skip check, removing a stale `local-test-plan.md` and `test -s` on it, and the Ensure Dependencies fast path.**

**Auto-skip (even when enabled):** skip only when every changed file is non-runtime (docs, `.gitignore`; any YAML or env file is runtime). An unresolvable base, a failed diff or an empty diff never skips. Run via Bash:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/classify.sh"
SB=$(n1_story_base) || { echo "ERROR: invalid story base" >&2; exit 1; }
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_REF=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || { [ -n "$SB" ] && echo "origin/$SB"; } || n1_config_val '.git.defaultBranch' )
SKIP=false
if BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) && CHANGED_FILES=$(git diff --name-only "$BASE" 2>/dev/null); then SKIP=$(n1_classify_local_test_skip "$CHANGED_FILES"); fi
n1_record_decision local-testing-auto-skip "$SKIP" '{}' "skip=$SKIP"
echo "LOCAL_TESTING_AUTO_SKIP=$SKIP"
if [ "$SKIP" = "true" ]; then n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"auto_skip"}'; fi
```
If `LOCAL_TESTING_AUTO_SKIP=true`: log under `## Key Decisions`: "Local testing skipped — documentation-only changes." Skip to Step 10 (PR CREATION).

**QA dedup gate (`test` mode only):** In `live` mode pytest-only QA does not cover infrastructure or live endpoints, so the gate never skips there; it still captures `QA_RUNNER_CMDS` for the planner. Run via Bash, substituting the resolved mode:
```bash
source ~/.n1/preamble.sh
LOCAL_TESTING_MODE="<resolved LOCAL_TESTING_MODE>"
QA_MD="$N1_HOME/memory/$ID/qa.md"
if [ -f "$QA_MD" ]; then
  RUNNER_CMDS=$(grep 'Runner command:' "$QA_MD" | sed 's/.*Runner command: *//')
  if [ -n "$RUNNER_CMDS" ]; then
    NON_PYTEST=$(echo "$RUNNER_CMDS" | grep -v '^pytest\b' | grep -v '^python -m pytest\b' || true)
    if [ -z "$NON_PYTEST" ] && [ "$LOCAL_TESTING_MODE" = "test" ]; then
      echo "QA_DEDUP_SKIP=true"
    else
      echo "QA_DEDUP_SKIP=false"
      echo "QA_RUNNER_CMDS<<EOF"
      echo "$RUNNER_CMDS"
      echo "EOF"
    fi
  fi
fi
```
- If `QA_DEDUP_SKIP=true`: mode is `test` and all Runner commands in qa.md are pytest — QA already covers the test surface.
  - Skip local testing entirely. Key decision: "Local Testing: skipped — QA dedup (test mode, all Runner commands are pytest)".
  - End the step:
    ```bash
    source ~/.n1/preamble.sh
    n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"qa_dedup"}'
    ```
  - Skip to Step 10 (PR CREATION).
- If `QA_DEDUP_SKIP=false`: mode is `live`, or at least one non-pytest Runner command exists — proceed to 9a. Capture the `QA_RUNNER_CMDS` value for injection into the planner prompt in 9a.

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before infrastructure/app startup. Marker-guarded no-op if already installed.

**Gates passed (not skipped):** read `procedures/local-testing-run.md` and follow it through 9a-9d; it ends this step exactly once on every exit (success, skipped, failed). Do not end the step here.
