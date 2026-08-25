
Run `n1_config_val '.localTesting.enabled'` (default: `false`).

> The gate key (`localTesting.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `localTesting.enabled` is `false`:** Skip to Step 10 (PR CREATION).

> **ORCHESTRATOR GUARDRAIL (local testing): do not run test suites, `pytest`/`make test`/`npm test`, coverage runs, package installs (`pip`, `uv`, `npm`), interpreter/venv discovery or repair, or app/infrastructure startup in this step. All execution belongs to the developer spawn in 9c. If the environment is broken, the developer reports it and it is routed through the `local_test_env_failure` escalation — the orchestrator never debugs it inline. The only permitted orchestrator commands here are the memory/config helpers, `git diff --stat` for the auto-skip check, and the Ensure Dependencies fast path.**

**Auto-skip conditions (even when enabled):**
- If the diff against the default branch contains ONLY non-runtime files (`.md`, `.txt`, `.yml`/`.yaml` config, `.gitignore`, `LICENSE`, `CHANGELOG`) → skip with message: "Local testing skipped — documentation/config-only changes."
- If `implementation.md` indicates no runtime-affecting code was modified → skip.
- Log skip reason in overview under `## Key Decisions`.

**Ensure dependencies (step mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before infrastructure/app startup. Marker-guarded no-op if already installed.

#### 9a. ANALYSIS (local-test-planner)

**Spawn agent:** local-test-planner

Resolve model for `local-test-planner`.

Spawn the local-test-planner agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/implementation.md` (what changed, which files), `$N1_HOME/memory/<ID>/ticket.md` (acceptance criteria), and `$N1_HOME/memory/<ID>/plan.md` if it exists, else `$N1_HOME/memory/<ID>/brainstorm.md` (design intent, scope). Their content is NOT inlined here."
- Read `localTesting.startCommand` from config: `n1_config_val '.localTesting.startCommand'` (default: empty). If non-empty, include in the prompt: "The project has a configured start command: `<value>`. Use this as the app start command instead of auto-detecting."
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

**If verdict is PASS:**
- Update overview: `[x] Local Testing`, set `step: local-testing`
- Proceed to Step 10 (PR CREATION)

**If verdict is FAIL:**
- Proceed to fix loop (9d)

**If infrastructure or app startup failed (not a code bug):**
- Do NOT enter the fix loop — these are environment issues, not code bugs
- Report the failure with full error output

**Step-mode escalation protocol (infrastructure failure).** → § Step-Mode Escalation Protocol with step=`local-testing`, id=`local_test_env_failure`, options=["Skip local testing: proceed to PR", "Abort: stop the pipeline"], context=infrastructure/startup failure with full error output, startup command, and readiness check result.

**text override:** Replace SKILL.md template `text` with: `"{PREAMBLE} Local testing could not start due to infrastructure/environment failure: {context}. Please advise."` where `PREAMBLE` is composed as in SKILL.md § Step-Mode Escalation Protocol (title from overview.md heading + Core Ask from ticket.md). Omit `PREAMBLE` and its trailing space if unavailable.

**Step result override:** In SKILL.md § Step-Mode Escalation Protocol step 2, use this command instead:
`n1_emit_step_result "local-testing" "escalation" "null" "{\"local_test_fix_cycle\":0}" "" "$N1_HOME/memory/$ID"`

**On re-run**, apply the answer for `local_test_env_failure`:
- "Skip local testing" → update overview (`[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped — environment failure"), record in `## Escalations`; run `n1_emit_step_result "local-testing" "pass" "null" "null" "" "$N1_HOME/memory/$ID"` and STOP.
- "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode: compose `PREAMBLE` (title from `$N1_HOME/memory/<ID>/overview.md` heading + Core Ask from `ticket.md`; omit if unavailable). **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely. Then: "{PREAMBLE} Infrastructure/startup failure — not a code bug. Options:"
  - "1 — Fix environment manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Abort"
- If 1: wait for user, then re-run 9c from the beginning
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

**Step-mode escalation protocol (fix loop).** → § Step-Mode Escalation Protocol with step=`local-testing`, id=`local_test_fix_exhausted`, options=["Retry with guidance: another fix attempt with your instructions", "Skip local testing: proceed to PR with failures documented in local-testing.md", "Abort: stop the pipeline"], context=cycles used + failing scenarios + error excerpts.

**Step result override:** In SKILL.md § Step-Mode Escalation Protocol step 2, use this command instead:
`n1_emit_step_result "local-testing" "escalation" "null" "{\"local_test_fix_cycle\":$local_test_fix_cycle}" "" "$N1_HOME/memory/$ID"`

**On re-run**, apply the answer for `local_test_fix_exhausted`:
- "Retry with guidance" → raise the loop ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci), record guidance in overview `## Escalations`, and continue the fix loop.
- "Skip local testing" → update overview `[x] Local Testing`, add key decision "Local Testing: skipped after fix-loop exhaustion" to `## Escalations`, and emit `outcome: "pass"`.
- "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

**Autonomy gate (full pipeline only):** → § Autonomy Gate (qualityEscalations) with step=`local-testing`, action=`skip local testing and proceed to PR`, ledger_context=`<scenarios that still fail after N fix cycles>`. Also update `## Escalations` with key decision: `Local Testing: skipped after fix-loop exhaustion (qualityEscalations=auto-accept)`.

In full pipeline mode: compose `PREAMBLE` (title from `$N1_HOME/memory/<ID>/overview.md` heading + Core Ask from `ticket.md`; omit if unavailable). **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely. Then prompt: "{PREAMBLE} After <N> local testing fix cycles, these scenarios still fail: [list]. Options:"
  - "1 — Fix manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Provide guidance for another fix attempt"
- If 3: reset the counter ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci) and continue with user's guidance.

**Cleanup guarantee:** cleanup runs after EVERY execution attempt, including failed ones. No orphan containers or processes between fix cycles.

**Step result (step mode) — pass path:**

When all local tests pass:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "local-testing" "pass" "pr" "null" "" "$N1_HOME/memory/$ID"
```
