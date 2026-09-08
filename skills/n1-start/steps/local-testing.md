
Run `n1_config_val '.localTesting.enabled'` (default: `false`).

> The gate key (`localTesting.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `localTesting.enabled` is `false`:** Skip to Step 10 (PR CREATION).

**Mode resolution:** Read `n1_config_val '.localTesting.mode'` (default: empty). If empty or absent, infer:
- If `n1_config_val '.localTesting.startCommand'` returns a non-empty value -> mode is `"live"`
- Otherwise -> mode is `"test"`

Capture the resolved mode as `LOCAL_TESTING_MODE` for use throughout this step.

**If mode is `"smoke"`:** Skip local testing entirely. Update overview: `[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped -- smoke tests deferred to n1-finish post-deploy". Emit telemetry:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "local-testing" 11 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=skip loop_iteration=null metadata='{"action_type":"smoke_deferred","skip_reason":"smoke_mode"}'
```
Skip to Step 10 (PR CREATION).

> **ORCHESTRATOR GUARDRAIL (local testing): do not run test suites, `pytest`/`make test`/`npm test`, coverage runs, package installs (`pip`, `uv`, `npm`), interpreter/venv discovery or repair, or app/infrastructure startup in this step. All execution belongs to the developer spawn in 9c. If the environment is broken, the developer reports it and it is routed through the `local_test_env_failure` escalation — the orchestrator never debugs it inline. The only permitted orchestrator commands here are the memory/config helpers, `git diff --stat` for the auto-skip check, and the Ensure Dependencies fast path.**

**Auto-skip conditions (even when enabled):**
- If the diff against the default branch contains ONLY non-runtime files (`.md`, `.txt`, `.yml`/`.yaml` config, `.gitignore`, `LICENSE`, `CHANGELOG`) → skip with message: "Local testing skipped — documentation/config-only changes."
- If `implementation.md` indicates no runtime-affecting code was modified → skip.
- Log skip reason in overview under `## Key Decisions`.

**QA dedup gate (even when enabled):** Run via Bash:
```bash
QA_MD="$N1_HOME/memory/$ID/qa.md"
if [ -f "$QA_MD" ]; then
  RUNNER_CMDS=$(grep 'Runner command:' "$QA_MD" | sed 's/.*Runner command: *//')
  if [ -n "$RUNNER_CMDS" ]; then
    NON_PYTEST=$(echo "$RUNNER_CMDS" | grep -v '^pytest\b' | grep -v '^python -m pytest\b' || true)
    if [ -z "$NON_PYTEST" ]; then
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
- If `QA_DEDUP_SKIP=true`: all Runner commands in qa.md are pytest — QA already covers the test surface.
  - Skip local testing entirely. Update overview: `[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped — QA dedup (all Runner commands are pytest)".
  - Emit telemetry:
    ```bash
    source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
    n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "local-testing" 9 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=skip loop_iteration=null metadata='{"action_type":"skipped","skip_reason":"qa_dedup"}'
    ```
  - Skip to Step 10 (PR CREATION).
- If `QA_DEDUP_SKIP=false`: at least one non-pytest Runner command exists — proceed to 9a. Capture the `QA_RUNNER_CMDS` value for injection into the planner prompt in 9a.

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before infrastructure/app startup. Marker-guarded no-op if already installed.

#### 9a. ANALYSIS (local-test-planner)

**Spawn agent:** local-test-planner

Resolve model for `local-test-planner`.

Spawn the local-test-planner agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/implementation.md` (what changed, which files), `$N1_HOME/memory/<ID>/ticket.md` (acceptance criteria), and `$N1_HOME/memory/<ID>/plan.md` if it exists, else `$N1_HOME/memory/<ID>/brainstorm.md` (design intent, scope). Their content is NOT inlined here."
- Read `localTesting.startCommand` from config: `n1_config_val '.localTesting.startCommand'` (default: empty). If non-empty, include in the prompt: "The project has a configured start command: `<value>`. Use this as the app start command instead of auto-detecting."
- Include the resolved mode in the prompt: "The local testing mode is `<LOCAL_TESTING_MODE>`. If mode is `test`, suppress Runtime First -- produce a test-suite-only plan with no infrastructure startup. If mode is `live`, enforce Runtime First as usual."
- If `QA_RUNNER_CMDS` is set (from the QA dedup gate above), include in the prompt: "The QA step already ran these test commands: `<QA_RUNNER_CMDS value, one per line>`. Do not duplicate these as ad-hoc scenarios — design test scenarios that complement them (e.g. infrastructure checks, curl endpoints, CLI flows that QA did not exercise)."
- Directive: "Output the plan in this exact structure:"

```markdown
## Local Test Plan

### Infrastructure
- **Services required:** <list or "None">
- **Start command:** <command or "N/A">
- **Readiness check:** <command>
- **Estimated setup time:** <time>

### Application
- **Start command:** <command>
- **Readiness signal:** <description>
- **Estimated startup time:** <time>

### Existing E2E Tests
- **Framework:** <detected framework or "None">
- **Run command:** <command or "N/A">
- **Coverage:** <which acceptance criteria covered, or "None detected">

### Automated Test Scenarios
1. **[Critical/Normal] <scenario name>** — Method: <curl/CLI/browser> — Command: `<exact command>` — Expected: <outcome>

{Omit if all acceptance criteria are covered by existing e2e tests.}

### Manual Verification Checklist
- [ ] <item>

### Cleanup
- <cleanup commands>
```

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/local-test-plan.md`

**Edge case — no testable scenarios:** If the plan has no existing e2e suite (`### Existing E2E Tests` Framework is "None" and Run command is "N/A") AND zero ad-hoc test scenarios in `### Automated Test Scenarios`, auto-skip: "Local testing analysis found no testable scenarios for this change. Proceeding to PR." Update overview: `[x] Local Testing`, set `step: local-testing`, add key decision: "Local Testing: skipped (no testable scenarios)". Skip to Step 10. If the plan has a valid e2e suite, do NOT auto-skip even if there are zero ad-hoc scenarios.

#### 9b. PLAN SUMMARY

Read `local-test-plan.md`. Print to the user:

```
Local Testing Plan for <ID>:

Infrastructure: <services summary or "None needed">
App start: <start command> → <readiness signal>
E2E suite: <framework and run command, or "None detected">
Ad-hoc scenarios: <N> automated checks, <M> manual verification items
Estimated time: <time estimate>
```

Proceed to 9c (EXECUTION).

#### 9c. EXECUTION (developer)

**Spawn agent:** developer

Resolve model for `developer`.

Spawn the developer agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/local-test-plan.md` (the test plan to execute) and `$N1_HOME/memory/<ID>/implementation.md` (context for debugging)."
- The value of `n1_config_val '.worktree.setup'` as `<SETUP>` (may be empty).
- Directive: "Execute the local test plan. Follow this sequence strictly:"
  - "0. Environment check: before anything else, verify the interpreter and test runner work in the worktree (e.g. `python -m pytest --version`, `npm test -- --help`, or the project's equivalent). If dependencies are missing and the project defines a setup command (`worktree.setup` in `$N1_HOME/config.json`, passed to you as `<SETUP>`), run it ONCE. If the environment still does not work, write a report with `Result: ENV_FAILURE` and the exact stderr, run cleanup, and STOP — do not attempt scenarios and do not try to repair the environment further."
  - "1. Infrastructure setup: run the start command from the plan. Poll readiness check with a 60s timeout. If infrastructure fails to start, report immediately with the error output and STOP — do not attempt scenarios."
  - "2. App startup: start the app in background. Poll the readiness signal with a 30s timeout. If app fails to start, capture stderr/stdout, report FAIL, run cleanup, and STOP."
  - "3. Existing e2e tests: if the plan has an 'Existing E2E Tests' section with a run command (not 'N/A' or 'None'), run that command. Record the full output. If no existing e2e suite, skip this step."
  - "4. Ad-hoc scenario execution: execute each scenario from 'Automated Test Scenarios' SEQUENTIALLY (not parallel — some may depend on prior state). Record PASS/FAIL per scenario with actual output. Continue through ALL scenarios even if some fail. If the plan says 'no ad-hoc scenarios needed', skip this step."
  - "5. Evidence capture: for each test/scenario, record HTTP response bodies and status codes, command stdout/stderr, relevant app log output, full error context for failures."
  - "6. Cleanup: ALWAYS runs, even on failure. Kill app process, tear down infrastructure, verify no orphan containers/processes."
- Directive: "CONSTRAINTS — you MUST follow these:"
  - "Do NOT modify production code — only execute and observe"
  - "Do NOT write or modify tests"
  - "Do NOT commit anything"
  - "Skip destructive or ambiguous commands, note why"
- Directive: "Write the report in this exact structure to `$N1_HOME/memory/<ID>/local-testing.md` (full overwrite):"

```markdown
## Local Testing Report

### Infrastructure
- **Status:** UP/DOWN (<details>)

### Application
- **Status:** Running/Failed (<details>)

### Existing E2E Test Results
- **Command:** <command run or "Skipped — no e2e suite detected">
- **Result:** PASS/FAIL/SKIPPED
- **Details:** <summary or failure output>

### Ad-Hoc Scenario Results
| # | Scenario | Result | Details |
|---|----------|--------|---------|

{Omit table if no ad-hoc scenarios were planned.}

### Manual Verification Checklist
- [ ] <item from plan>

### Cleanup
- Infrastructure: <status>
- App process: <status>

### Verdict: PASS / FAIL
```

- Output-path directive: "Write your full Local Testing Report to `$N1_HOME/memory/<ID>/local-testing.md` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
  `Verdict: PASS|FAIL` / `Failure class: infra|code-bug|none` / per-scenario one-liners (`<name>: PASS|FAIL — <detail>`) / cleanup status. Do NOT return the full report."

After the agent returns:
- The agent wrote `$N1_HOME/memory/<ID>/local-testing.md` itself. Verify it:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  n1_verify_dependencies "$N1_HOME/memory/$ID" local-testing.md
  ```
  If missing/empty (agent failed to write), write the returned compact summary block to `local-testing.md` as a fallback and note the gap in overview's `## Key Decisions`.

- Extract telemetry metadata from the report and plan. Run via Bash:
  ```bash
  LOCAL_TESTING_REPORT="$N1_HOME/memory/$ID/local-testing.md"
  LOCAL_TEST_PLAN="$N1_HOME/memory/$ID/local-test-plan.md"
  QA_MD="$N1_HOME/memory/$ID/qa.md"

  # Parse Infrastructure Status from report (first Status: line, under ### Infrastructure)
  INFRA_STATUS=$(awk '/^### Infrastructure/{found=1} found && /\*\*Status:\*\*/{print; exit}' "$LOCAL_TESTING_REPORT" | sed 's/.*\*\*Status:\*\* *//')
  if echo "$INFRA_STATUS" | grep -qiE '\bup\b|started|running'; then
    INFRA_STARTED=true
  else
    INFRA_STARTED=false
  fi

  # Parse Application Status from report (Status: line under ### Application)
  APP_STATUS=$(awk '/^### Application/{found=1} found && /\*\*Status:\*\*/{print; exit}' "$LOCAL_TESTING_REPORT" | sed 's/.*\*\*Status:\*\* *//')
  if echo "$APP_STATUS" | grep -qiE 'running|started|\bup\b'; then
    APP_STARTED=true
  else
    APP_STARTED=false
  fi

  # Derive action_type from infra_started
  if [ "$INFRA_STARTED" = "true" ]; then
    ACTION_TYPE="live"
  else
    ACTION_TYPE="test_only"
  fi

  # Extract services list from plan (Services required: line under ### Infrastructure)
  SERVICES_RAW=$(awk '/^### Infrastructure/{found=1} found && /Services required:/{print; exit}' "$LOCAL_TEST_PLAN" 2>/dev/null | sed 's/.*Services required: *//')
  if [ -z "$SERVICES_RAW" ] || echo "$SERVICES_RAW" | grep -qi '^none$'; then
    SERVICES_JSON="[]"
  else
    # Convert comma/space-separated service names to JSON array
    SERVICES_JSON=$(echo "$SERVICES_RAW" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | sed 's/\(.*\)/"\1"/' | paste -sd ',' | sed 's/^/[/;s/$/]/')
  fi

  # Extract scenario method types from plan (Method: curl/CLI/browser/script)
  TYPES_RAW=$(grep -oiE 'Method: [A-Za-z]+' "$LOCAL_TEST_PLAN" 2>/dev/null | sed 's/Method: *//' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ -z "$TYPES_RAW" ]; then
    SCENARIO_TYPES_JSON="[]"
  else
    SCENARIO_TYPES_JSON=$(echo "$TYPES_RAW" | tr ',' '\n' | sed 's/\(.*\)/"\1"/' | paste -sd ',' | sed 's/^/[/;s/$/]/')
  fi

  # Compute qa_overlap_pct: fraction of QA runner commands also present in the local test plan
  QA_RUNNER_COUNT=$(grep -c 'Runner command:' "$QA_MD" 2>/dev/null || echo 0)
  if [ "$QA_RUNNER_COUNT" -gt 0 ]; then
    MATCH_COUNT=0
    while IFS= read -r rcmd; do
      rcmd_trimmed=$(echo "$rcmd" | sed 's/^ *//;s/ *$//')
      [ -z "$rcmd_trimmed" ] && continue
      grep -qF "$rcmd_trimmed" "$LOCAL_TEST_PLAN" 2>/dev/null && MATCH_COUNT=$((MATCH_COUNT + 1))
    done < <(grep 'Runner command:' "$QA_MD" | sed 's/.*Runner command: *//')
    QA_OVERLAP_PCT=$((MATCH_COUNT * 100 / QA_RUNNER_COUNT))
  else
    QA_OVERLAP_PCT=null
  fi

  LOCAL_TESTING_METADATA="{\"action_type\":\"$ACTION_TYPE\",\"infra_started\":$INFRA_STARTED,\"app_started\":$APP_STARTED,\"services\":$SERVICES_JSON,\"scenario_types\":$SCENARIO_TYPES_JSON,\"qa_overlap_pct\":$QA_OVERLAP_PCT}"
  echo "$LOCAL_TESTING_METADATA"
  ```

**If verdict is PASS:**
- Update overview: `[x] Local Testing`, set `step: local-testing`
- Emit step-end telemetry:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
  n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "local-testing" 11 "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=pass loop_iteration=null metadata="$LOCAL_TESTING_METADATA"
  ```
- Proceed to Step 10 (PR CREATION)

**If verdict is FAIL:**
- Proceed to fix loop (9d)

**If infrastructure or app startup failed (not a code bug):**
- Do NOT enter the fix loop — these are environment issues, not code bugs
- Report the failure with full error output

Compose `PREAMBLE` (title from `$N1_HOME/memory/<ID>/overview.md` heading + Core Ask from `ticket.md`; omit if unavailable). **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely. Then: "{PREAMBLE} Infrastructure/startup failure — not a code bug. Options:"
  - "1 — Fix environment manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Abort"
- If 1: wait for user, then re-run 9c from the beginning. **Headless:** under `N1_HEADLESS=1`, apply SKILL.md § Headless Guard instead of prompting.
- If 2: update overview (`[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped — environment failure"), proceed to Step 10
- If 3: stop

#### 9d. FIX LOOP (if local testing failed)

If local testing verdict is FAIL (e2e tests or ad-hoc scenarios failed):

**Spawn agent:** developer (fix mode)

Resolve model for `developer`.

Pass to developer:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/local-testing.md` (which scenarios failed, with evidence), `$N1_HOME/memory/<ID>/local-test-plan.md` (what was expected), `$N1_HOME/memory/<ID>/implementation.md` (original implementation context)."
- Directive: "Fix the production code to make the failing scenarios pass. Constraints:"
  - "Fix production code ONLY (not the test plan)"
  - "Atomic commits per fix"
  - "Same escalation rules as implementation — high blast radius + low confidence → ask user"
- Output-path directive: "After applying fixes, record your 'Fixes Applied' report (your standard Fix Cycle output format) in `$N1_HOME/memory/<ID>/implementation.md` yourself, under a `## Local-Test Fix Cycle <N>` heading where `<N>` is the current `local_test_fix_cycle` value. If a `## Local-Test Fix Cycle <N>` section for this N already exists, REPLACE it (idempotent upsert — safe on re-run), never duplicate it. Return to the orchestrator ONLY: the list of commit SHAs with one-line summaries, and `Findings fixed: N/M`."

After developer returns:
- Run via Bash (durable across resume):
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "local_test_fix_cycle"
  ```
- Re-run FULL execution (Step 9c) — all scenarios, not just failed ones (catches regressions)
- **Bounded loop:** read `local_test_fix_cycle` from overview frontmatter. Stop after `localTesting.maxFixAttempts` cycles (config, default 3). On exhaustion, escalate instead of looping forever. The bound and its default are declared in `pipeline.json` `loops[]` (`local_testing_fix`).

**Autonomy gate:** → § Autonomy Gate (qualityEscalations) with step=`local-testing`, action=`skip local testing and proceed to PR`, ledger_context=`<scenarios that still fail after N fix cycles>`. Also update `## Escalations` with key decision: `Local Testing: skipped after fix-loop exhaustion (qualityEscalations=auto-accept)`.

**Headless:** under `N1_HEADLESS=1`, apply SKILL.md § Headless Guard instead of prompting.

Compose `PREAMBLE` (title from `$N1_HOME/memory/<ID>/overview.md` heading + Core Ask from `ticket.md`; omit if unavailable). **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely. Then prompt: "{PREAMBLE} After <N> local testing fix cycles, these scenarios still fail: [list]. Options:"
  - "1 — Fix manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Provide guidance for another fix attempt"
- If 3: reset the counter ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci) and continue with user's guidance.

**Cleanup guarantee:** cleanup runs after EVERY execution attempt, including failed ones. No orphan containers or processes between fix cycles.
