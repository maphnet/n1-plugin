
Run `n1_config_val '.localTesting.enabled'` (default: `false`).

> The gate key (`localTesting.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `localTesting.enabled` is `false`:** Skip to Step 10 (PR CREATION).

**Auto-skip conditions (even when enabled):**
- If the diff against the default branch contains ONLY non-runtime files (`.md`, `.txt`, `.yml`/`.yaml` config, `.gitignore`, `LICENSE`, `CHANGELOG`) → skip with message: "Local testing skipped — documentation/config-only changes."
- If `implementation.md` indicates no runtime-affecting code was modified → skip.
- Log skip reason in overview under `## Key Decisions`.

**Ensure dependencies (step mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before infrastructure/app startup. Marker-guarded no-op if already installed.

#### 9a. ANALYSIS (solution-architect)

**Spawn agent:** solution-architect

Resolve model for `solution-architect`.

Spawn the solution-architect agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/implementation.md` (what changed, which files), `$N1_HOME/memory/<ID>/ticket.md` (acceptance criteria), and `$N1_HOME/memory/<ID>/plan.md` if it exists, else `$N1_HOME/memory/<ID>/brainstorm.md` (design intent, scope). Their content is NOT inlined here."
- Directive: "Analyze this project for local end-to-end testing. Your task is to produce a structured test plan — do NOT execute any commands that modify state. You MAY run read-only commands (ls, cat, grep, docker compose config) to discover infrastructure."
- Directive: "Detect the following from the project:"
  - "1. Infrastructure: what services the app needs (DB, Redis, queues, external APIs), how they start (docker-compose, manual), what ports/env vars are required. Check docker-compose*.yml, Dockerfile*, .env.example, CLAUDE.md."
  - "2. App startup: how the app starts locally (npm run dev, cargo run, etc.), what the readiness signal is (port open, health endpoint, specific log line). Check package.json scripts, Makefile, Cargo.toml, CLAUDE.md."
  - "3. Test scenarios: concrete test scenarios based on changed functionality + acceptance criteria. Each scenario has: description, method (curl/CLI/browser), command or URL, expected outcome. Prioritize critical path first. Scope to changed functionality ONLY."
  - "4. Manual checklist: things the agent cannot verify automatically — visual UI changes, complex multi-step workflows requiring human judgment."
  - "5. Cleanup plan: how to tear down services and kill processes after testing."
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

### Automated Test Scenarios
1. **[Critical/Normal] <scenario name>**
   - Method: <curl/CLI/browser>
   - Command: `<exact command>`
   - Expected: <expected outcome>

### Manual Verification Checklist
- [ ] <item>

### Cleanup
- <cleanup commands>
```

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/local-test-plan.md`

**Edge case — no testable scenarios:** If the analysis produces zero automated test scenarios (no startable app, no testable endpoints, purely library/SDK changes), auto-skip: "Local testing analysis found no testable scenarios for this change. Proceeding to PR." Update overview: `[x] Local Testing`, set `step: local-testing`, add key decision: "Local Testing: skipped (no testable scenarios)". Skip to Step 10.

#### 9b. PLAN SUMMARY

Read `local-test-plan.md`. Print to the user:

```
Local Testing Plan for <ID>:

Infrastructure: <services summary or "None needed">
App start: <start command> → <readiness signal>
Scenarios: <N> automated checks, <M> manual verification items
Estimated time: <time estimate>
```

Proceed to 9c (EXECUTION).

#### 9c. EXECUTION (developer)

**Spawn agent:** developer

Resolve model for `developer`.

Spawn the developer agent with:
- The paths to its inputs — instruct the agent: "Read these files yourself: `$N1_HOME/memory/<ID>/local-test-plan.md` (the test plan to execute) and `$N1_HOME/memory/<ID>/implementation.md` (context for debugging)."
- Directive: "Execute the local test plan. Follow this sequence strictly:"
  - "1. Infrastructure setup: run the start command from the plan. Poll readiness check with a 60s timeout. If infrastructure fails to start, report immediately with the error output and STOP — do not attempt scenarios."
  - "2. App startup: start the app in background. Poll the readiness signal with a 30s timeout. If app fails to start, capture stderr/stdout, report FAIL, run cleanup, and STOP."
  - "3. Scenario execution: execute each scenario SEQUENTIALLY (not parallel — some may depend on prior state). Record PASS/FAIL per scenario with actual output. Continue through ALL scenarios even if some fail."
  - "4. Evidence capture: for each scenario, record HTTP response bodies and status codes, command stdout/stderr, relevant app log output, full error context for failures."
  - "5. Cleanup: ALWAYS runs, even on failure. Kill app process, tear down infrastructure, verify no orphan containers/processes."
- Directive: "CONSTRAINTS — you MUST follow these:"
  - "Do NOT modify production code — only execute and observe"
  - "Do NOT write or modify tests"
  - "Do NOT commit anything"
  - "Skip destructive or ambiguous commands, note why"
- Directive: "Output the report in this exact structure:"

```markdown
## Local Testing Report

### Infrastructure
- **Status:** UP/DOWN (<details>)

### Application
- **Status:** Running/Failed (<details>)

### Scenario Results
| # | Scenario | Result | Details |
|---|----------|--------|---------|
| 1 | <name> | PASS/FAIL | <details> |

### Manual Verification Checklist
- [ ] <item from plan>

### Cleanup
- Infrastructure: <status>
- App process: <status>

### Verdict: PASS / FAIL
<PASS if all automated scenarios passed, FAIL if any failed>
```

After the agent returns:
- Write its output to `$N1_HOME/memory/<ID>/local-testing.md`

**If verdict is PASS:**
- Update overview: `[x] Local Testing`, set `step: local-testing`
- Proceed to Step 10 (PR CREATION)

**If verdict is FAIL:**
- Proceed to fix loop (9d)

**If infrastructure or app startup failed (not a code bug):**
- Do NOT enter the fix loop — these are environment issues, not code bugs
- Report the failure with full error output

**Step-mode escalation protocol (infrastructure failure).** In step mode there is no interactive channel — do NOT print a question for the user. When infrastructure or app startup fails:

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "local-testing",
     "questions": [{
       "id": "local_test_env_failure",
       "text": "<one-paragraph description of the infrastructure/startup failure with full error output>",
       "options": ["Skip local testing: proceed to PR", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<error output, startup command, readiness check result>"
     }]
   }
   ```
2. Run via Bash:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   n1_emit_step_result "local-testing" "escalation" "null" "{\"local_test_fix_cycle\":0}"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `local_test_env_failure`:
   - "Skip local testing" → update overview (`[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped — environment failure"), record in `## Escalations`; run via Bash: `n1_emit_step_result "local-testing" "pass" "null" "null"` and STOP.
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt below unchanged.

In full pipeline mode: "Infrastructure/startup failure — not a code bug. Options:"
  - "1 — Fix environment manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Abort"
- If 1: wait for user, then re-run 9c from the beginning
- If 2: update overview (`[x] Local Testing`, set `step: local-testing`, key decision: "Local Testing: skipped — environment failure"), proceed to Step 10
- If 3: stop

#### 9d. FIX LOOP (if local testing failed)

If any automated scenario failed:

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

**Step-mode escalation protocol (fix loop).** In step mode there is no interactive channel — do NOT print a question for the user. When the fix loop exhausts its bound:

1. Write `$N1_HOME/memory/<ID>/escalation/request.json` (create the directory if needed):
   ```json
   {
     "run_id": "<value of the N1_RUN_ID environment variable>",
     "step": "local-testing",
     "questions": [{
       "id": "local_test_fix_exhausted",
       "text": "<one-paragraph description of what is blocked and why, with concrete specifics>",
       "options": ["Retry with guidance: another fix attempt with your instructions", "Skip local testing: proceed to PR with failures documented in local-testing.md", "Abort: stop the pipeline"],
       "recommendation": "<the option you would pick, with a one-line reason>",
       "context": "<cycles used, failing scenarios, error excerpts>"
     }]
   }
   ```
2. Run via Bash:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   n1_emit_step_result "local-testing" "escalation" "null" "{\"local_test_fix_cycle\":$local_test_fix_cycle}"
   ```
   Then STOP.
3. **On re-run:** check `$N1_HOME/memory/<ID>/escalation/response.json`. If it exists and its `run_id` matches `N1_RUN_ID`, apply the answer for `local_test_fix_exhausted`:
   - "Retry with guidance" → raise the loop ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci), record the guidance in overview `## Escalations`, and continue the fix loop using it.
   - "Skip local testing" → update overview `[x] Local Testing`, add key decision "Local Testing: skipped after fix-loop exhaustion" to `## Escalations`, and emit `outcome: "pass"` (pipeline proceeds to PR).
   - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

In full pipeline mode this protocol does NOT apply — keep the interactive prompt below unchanged.

In full pipeline mode: "After <N> local testing fix cycles, these scenarios still fail: [list]. Options:"
  - "1 — Fix manually, type 'continue' to re-test"
  - "2 — Skip local testing, proceed to PR"
  - "3 — Provide guidance for another fix attempt"
- If 3: reset the counter ceiling to `maxFixAttempts × 2` (hard ceiling, same pattern as n1-ci) and continue with user's guidance.

**Cleanup guarantee:** cleanup runs after EVERY execution attempt, including failed ones. No orphan containers or processes between fix cycles.

