<!-- n1:step-snippet-exception: mode-branch step_end calls and the none-stub write are mutually exclusive and cannot share one invocation; the user answer sits between the offer and persist snippets -->
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

Run `n1_config_val '.localTesting.enabled'` (default: `true`).

```bash
source ~/.n1/preamble.sh
n1_step_begin "local-testing" 11
rm -f "$N1_HOME/memory/$ID/local-testing.md"
GATE_ENABLED=$(n1_config_val '.localTesting.enabled' 2>/dev/null || echo 'true')
n1_record_decision local-testing-gate "$( [ "${GATE_ENABLED:-true}" = "true" ] && echo true || echo false )" '{"config":"localTesting.enabled"}' "enabled=${GATE_ENABLED:-true}"
[ "${GATE_ENABLED:-true}" = "true" ] || n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"disabled"}'
LT_ROOT=$(git rev-parse --show-toplevel)
echo "LOCAL_TESTING_MODE=$(n1_resolve_local_testing_mode "$LT_ROOT")"
echo "LOCAL_TESTING_OFFER=$(n1_local_testing_offer "$LT_ROOT")"
```

> The gate key (`localTesting.enabled`) and its default (`true`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `localTesting.enabled` is `false`:** Skip to Step 10 (PR CREATION).

**Mode resolution:** `LOCAL_TESTING_MODE` was resolved above via `n1_resolve_local_testing_mode`. Precedence (in `lib/config.sh`): explicit `localTesting.mode` `"live"` or `"smoke"` > `localTesting.autoLive: true` plus a root compose file (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`) -> `"live"` > non-empty `localTesting.startCommand` -> `"live"` > `"none"`. Any other `mode` value (legacy `"test"`) is ignored.

Capture the resolved mode as `LOCAL_TESTING_MODE` for use throughout this step.

**Live-testing offer (N1-559):** `LOCAL_TESTING_OFFER` is non-empty only when local testing is enabled, the mode resolved to `"none"`, `localTesting.autoLive` is absent (an explicit `false` means the user already declined) and a runnable service was detected: `compose` (root compose file) or `start:<cmd>` (detected start command, `n1_detect_start_command`). If it is empty, skip this block.
- Headless (`N1_HEADLESS=1`): do not ask. Run `source ~/.n1/preamble.sh; n1_record_decision local-testing-offer false '{"headless":true}' "offer=<compose|start>"` and add under `## Key Decisions`: "Live local testing not offered (headless run); detected the detected service. Set `localTesting.autoLive` or `localTesting.startCommand` to enable it." Keep the resolved mode.
- If N1 already asked to enable live local testing in this conversation (the session-start `LOCAL TESTING OFFER`), do not ask again and do not write config.
- Otherwise ask the user once (format: `<N1_ROOT>/references/question-format.md`):
  ```
  Run live local testing automatically after review?
  Detected <the root compose file | start command `<cmd>`>. Without it, this run skips local testing and the PR states that live verification was not run.
  1 — Yes (Recommended): a runnable service was detected, and live local testing is the only pipeline step that starts it before the PR
  2 — No: works when the change needs no running service; N1 records autoLive: false and does not ask again
  ```
  For `start:<cmd>` the user may answer Yes with an edited command. `<cmd>` comes from repo files: show it to the user, but never paste it, or the edited command, into a shell literal.
- Persist the answer, then re-resolve the mode and use the new `LOCAL_TESTING_MODE`:
  ```bash
  source ~/.n1/preamble.sh
  n1_local_testing_offer_write <compose | start | no> "$(git rev-parse --show-toplevel)" || echo "WARN: config not updated; continuing with the current mode" >&2
  n1_record_decision local-testing-offer '<yes|no>' '{}' "offer=<compose|start>"
  echo "LOCAL_TESTING_MODE=$(n1_resolve_local_testing_mode "$(git rev-parse --show-toplevel)")"
  ```
  Use `start` for the detected command: the helper re-detects it. For an edited command, replace the write line with `n1_local_testing_offer_write start-stdin <<'N1CMD' || echo "WARN: config not updated; continuing with the current mode" >&2`, then the edited command on its own line, then `N1CMD` (the helper rejects control characters).
  Append an audit row to the Decision Ledger in overview.md: `| local-testing | scope | C | [asked] | Enable live local testing? | <yes/no> | - | user answer to live-testing offer | --- |`.

**If mode is `"smoke"`:** Skip local testing entirely. Key decision: "Local Testing: skipped -- post-deploy verification follows its separate configuration". End the step:
```bash
source ~/.n1/preamble.sh
n1_step_end "local-testing" 11 skipped '{"action_type":"smoke_deferred","skip_reason":"smoke_mode"}'
```
Skip to Step 10 (PR CREATION).

**If mode is `"none"`:** no live verification is configured. Do not dispatch the local-test-planner or the developer. Key decision: "Local Testing: skipped — no live verification configured". Write the stub report (tech-writer and Gate 3 print its first line) and end the step:
```bash
source ~/.n1/preamble.sh
printf '%s\n' 'Local testing: not run — no live verification configured for this project' > "$N1_HOME/memory/$ID/local-testing.md"
n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"no_live_verification"}'
```
Skip to Step 10 (PR CREATION).

> **ORCHESTRATOR GUARDRAIL (local testing): do not run test suites, `pytest`/`make test`/`npm test`, coverage runs, package installs (`pip`, `uv`, `npm`), interpreter/venv discovery or repair, or app/infrastructure startup in this step. All execution belongs to the developer spawn in 9c. If the environment is broken, the developer reports it and it is routed through the `local_test_env_failure` escalation — the orchestrator never debugs it inline. The only permitted orchestrator commands here are the memory/config helpers (including the live-testing offer helpers and the stub write), `git diff --no-renames --name-only` and `n1_classify_local_test_skip` for the auto-skip check, removing a stale `local-test-plan.md` and `test -s` on it, and the Ensure Dependencies fast path.**

**Auto-skip (even when enabled):** skip only when every changed file is non-runtime (docs, `.gitignore`; any YAML or env file is runtime). An unresolvable base, a failed diff or an empty diff never skips. Run via Bash:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/classify.sh"
SB=$(n1_story_base) || { echo "ERROR: invalid story base" >&2; exit 1; }
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_REF=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || { [ -n "$SB" ] && echo "origin/$SB"; } || n1_config_val '.git.defaultBranch' )
SKIP=false
if BASE=$(git merge-base "$BASE_REF" HEAD 2>/dev/null) && CHANGED_FILES=$(git diff --no-renames --name-only "$BASE" 2>/dev/null); then SKIP=$(n1_classify_local_test_skip "$CHANGED_FILES"); fi
n1_record_decision local-testing-auto-skip "$SKIP" '{}' "skip=$SKIP"
echo "LOCAL_TESTING_AUTO_SKIP=$SKIP"
if [ "$SKIP" = "true" ]; then n1_step_end "local-testing" 11 skipped '{"action_type":"skipped","skip_reason":"auto_skip"}'; fi
```
If `LOCAL_TESTING_AUTO_SKIP=true`: log under `## Key Decisions`: "Local testing skipped — documentation-only changes." Skip to Step 10 (PR CREATION).

**QA runner commands:** capture the commands the QA step already ran, for the planner prompt in 9a. Run via Bash:
```bash
source ~/.n1/preamble.sh
QA_MD="$N1_HOME/memory/$ID/qa.md"
if [ -f "$QA_MD" ]; then
  RUNNER_CMDS=$(grep 'Runner command:' "$QA_MD" | sed 's/.*Runner command: *//')
  if [ -n "$RUNNER_CMDS" ]; then
    echo "QA_RUNNER_CMDS<<EOF"
    echo "$RUNNER_CMDS"
    echo "EOF"
  fi
fi
```
Capture the `QA_RUNNER_CMDS` value (may be empty) for injection into the planner prompt in 9a.

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before infrastructure/app startup. Marker-guarded no-op if already installed.

**Gates passed (not skipped):** read `procedures/local-testing-run.md` and follow it through 9a-9d; it ends this step exactly once on every exit (success, skipped, failed). Do not end the step here.
