---
name: n1-ci
description: "Monitor CI checks after PR creation. Auto-fixes failures via developer agent, escalates to user after max attempts. Usage: /n1:n1-ci or /n1:n1-ci #123"
argument-hint: "[PR#]"
model: sonnet
effort: low
---

# N1 CI Watch & Fix

## Overview

Monitor CI checks on a pull request, classify failures, and delegate fixes to the developer agent. The user is only involved when max fix attempts are exhausted or when an unknown check falls below the confidence threshold.

**Announce at start:** "I'm using the n1-ci skill to monitor CI checks."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

Returns the config override if set, otherwise the agent's frontmatter default.

## Prerequisites

Check if `gh` CLI is available and authenticated:

```bash
gh auth status
```

If not authenticated: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.**

## Step 1: Resolve PR Number

**If argument provided** (e.g., `#123` or `123`):
- Strip `#` prefix if present
- Use the number directly

**If no argument:**
- Detect current branch and find its open PR:

```bash
gh pr view --json number,url,headRefName --jq '.number'
```

- If no PR found: "No open PR found for the current branch. Create a PR first or specify a PR number: `/n1:n1-ci #123`" **STOP.**

Capture the PR number and URL for reporting.

## Step 2: Read CI Check Config

Read the `ciChecks` section from config:
- `n1_config_val '.ciChecks.maxFixAttempts'` — default: `3`
- `n1_config_val '.ciChecks.confidenceThreshold'` — default: `0.7`
- `categories` — default: built-in category map (see below)

If `ciChecks.enabled` is explicitly `false`: "CI checks are disabled in config." **STOP.**

**Default categories** (used when config has no `ciChecks.categories`):

| Category | Patterns | Default Behavior |
|----------|----------|-----------------|
| lint | lint, eslint, prettier, format, style, biome | auto-fix |
| typecheck | typecheck, tsc, mypy, type-check, pyright | auto-fix |
| test | test, jest, pytest, spec, vitest, mocha | auto-fix |
| build | build, compile, webpack, vite, esbuild | auto-fix |
| security | security, snyk, dependabot, codeql, sast | auto-fix |
| infra | timeout, runner, infrastructure | auto-fix |

## Step 3: Poll for CI Checks

> **IMPORTANT — polling discipline:** Run each `gh pr checks` poll as a **separate, individual shell command**. NEVER combine polling into a bash `while`-loop, background process, or any other single long-running shell command. Sleep between polls via a standalone `sleep 30` command, then run the next poll command separately. This keeps every poll result visible in your reasoning context.

### Phase 1 — Wait for checks to register (up to 15 min)

1. Run `sleep 15` (initial registration delay).
2. Run `gh pr checks <PR#> --json name,state,conclusion,detailsUrl` as a **separate shell command**.
3. If the output is empty or contains no checks → run `sleep 30`, then poll again (go to step 2).
4. If no checks have appeared after 15 minutes total → report: "No CI checks appeared after 15 minutes. The repository may not have CI configured." **STOP.**
5. Once checks appear → enter Phase 2.

### Phase 2 — Poll until resolution (up to 30 min total)

Each iteration is a **separate shell command** — never a loop:

1. Run `gh pr checks <PR#> --json name,state,conclusion,detailsUrl`.
2. Parse the JSON. Count checks by state:
   - **Passed:** `conclusion` is `SUCCESS`, `NEUTRAL`, or `SKIPPED`
   - **Failed:** `conclusion` is `FAILURE`
   - **Pending:** `state` is not `COMPLETED`
3. Report: `"CI: N passed, M failed, K pending of T total"`
4. **Decision tree:**
   - All completed, none failed → proceed to **Step 4** (all green)
   - All completed, some failed → proceed to **Step 4** (evaluate failures)
   - **Some failed, others still pending → enter Phase 3** (grace period)
   - None failed, some still pending → run `sleep 30`, then repeat from step 1
5. **Timeout:** If 30 minutes of total polling time have elapsed and checks are still pending → report which checks are still pending, ask user: "CI checks are still running after 30 minutes. Wait longer or skip?" **STOP and wait for user response.**

### Phase 3 — Failure grace period (max 60s)

Once at least one failure is detected but other checks are still pending:

1. Log: `"Failure detected. Waiting up to 60s for remaining checks to finish or fail."`
2. Run up to 2 more polls (run `sleep 30` then `gh pr checks ...` each time — still individual commands).
3. After 2 grace polls OR all checks completed (whichever comes first) → proceed to **Step 4** with all currently-known results.

## Step 4: Evaluate Results

Once all checks have `state: COMPLETED`:

**If all checks have `conclusion: SUCCESS` (or `NEUTRAL` or `SKIPPED`):**
- Report: "All CI checks passed." → Go to **Step 7** (Report).

**If any checks have `conclusion: FAILURE`:**
- Collect all failed checks
- Continue to **Step 5** (Classify & Fix)

## Step 5: Classify Failures

For each failed check, classify by matching its `name` against category patterns (case-insensitive substring match):

1. Iterate through configured categories
2. For each category, check if any pattern is a substring of the check name
3. First matching category wins
4. If no category matches → classify as `unknown`

**Determine behavior for each failed check:**
- Category behavior is `auto-fix` → developer agent handles it
- Category behavior is `escalate` → skip developer agent, ask user immediately
- Category behavior is `skip` → ignore this check entirely
- Category is `unknown` → developer agent assesses confidence (see Step 5b)

### Step 5a: Fetch Failed Run Logs

For each failed check that needs fixing (not `skip` or `escalate`):

Extract the run ID from the `detailsUrl` (the URL contains the run ID in the path: `https://github.com/<owner>/<repo>/actions/runs/<run-id>/...`).

```bash
gh run view <run-id> --log-failed 2>&1 | head -500
```

Truncate to 500 lines per check to keep context manageable. Capture the output for the developer agent.

### Step 5b: Unknown Category Confidence Check

For checks classified as `unknown`: include them in the developer agent spawn. The developer agent assesses its confidence (0-1) in the fix. After the developer returns:

- If confidence >= `confidenceThreshold` → accept the fix (already applied)
- If confidence < `confidenceThreshold` → present to user:
  ```
  CI check "<check name>" failed. The developer agent assessed low confidence
  in the fix (confidence: <N>).

  Failed check logs:
  <truncated logs>

  Developer agent's analysis:
  <agent's assessment>

  How would you like to proceed?
  1 — Accept the proposed fix
  2 — Provide guidance for a different fix
  3 — Skip this check
  ```

## Step 6: Fix Cycle

**Batch all fixable failures** from a single CI run into one developer agent spawn.

**Spawn agent:** developer

Resolve model for `developer`.

Pass to developer:
- List of failed checks with their categories
- Failed run logs for each check (`--log-failed` output)
- Current git diff against base branch: `git diff $(git merge-base origin/<default-branch> HEAD)..HEAD`
- N1 memory files if available: `plan.md`, `implementation.md` (so developer understands intent)
- For each failed check: the check name, category, and truncated log output
- Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one answering a current question rather than verifying committed code) under `$N1_HOME/scratch/benchmarks/` or `$N1_HOME/scratch/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Fixes that need real regression coverage still get committed tests in the repo as usual. When unsure, default to scratch.

**Developer agent instructions (append to standard developer prompt):**

```
You are fixing CI failures on an open pull request. For each failed check:

1. Read the failure logs carefully
2. Identify the root cause in the codebase
3. Implement the minimal fix
4. Run relevant local checks if possible (e.g., lint, typecheck, test commands)

For "unknown" category checks: include a confidence assessment (0.0-1.0) in your
output indicating how confident you are that your fix resolves the issue.

Commit all fixes with descriptive messages (e.g., "fix: resolve eslint no-unused-vars in auth.ts").
Push to the PR branch after committing.

Output format:
## CI Fixes Applied

### Check: <check name> (<category>)
- **Root cause:** <what caused the failure>
- **Fix:** <what was changed>
- **Files:** <list of files modified>
- **Confidence:** <0.0-1.0> (only for unknown category)

## Summary
- Checks fixed: N/M
- Commits: <list of commit messages>
```

**After developer returns:**

1. Check for `unknown` category fixes with confidence below threshold → present to user (Step 5b flow)
2. Push changes if developer didn't already: `git push`
3. ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "ci_fix_cycle"
   ```
4. If `ci_fix_cycle` < `maxFixAttempts` → go back to **Step 3** (Poll for new CI run)
5. If cycle counter >= `maxFixAttempts` → go to **Step 6b** (Exhausted)

### Step 6b: Max Attempts Exhausted

If after `maxFixAttempts` cycles there are still failing checks:

```
CI checks are still failing after <N> fix attempts.

Remaining failures:
- <check name>: <last failure summary>
- <check name>: <last failure summary>

Fix history:
- Cycle 1: Fixed <checks>, remaining: <checks>
- Cycle 2: Fixed <checks>, remaining: <checks>
- Cycle 3: <checks still failing>

How would you like to proceed?
1 — Provide guidance for another fix attempt
2 — Skip CI checks and finalize (PR will have red CI)
3 — I'll fix manually, then type "continue" to re-poll
```

**Wait for user response:**
- **1:** Accept user guidance, spawn developer with the guidance as additional context, increment max attempts by 1 — up to a hard ceiling of 2×`maxFixAttempts` total, beyond which only options 2 and 3 are offered — log the extension to the CI status section, then go back to Step 3
- **2:** Proceed to Step 7 with CI status = failing
- **3:** Wait for user to say "continue", then go back to Step 3 (reset cycle counter)

## Step 7: Report & Memory Update

### Update overview.md

If N1 memory exists (`$N1_HOME/memory/$ID/overview.md`):

Add CI status section:
```markdown
## CI Status
- **Result:** PASS / FAIL (with N fix cycles)
- **Fix cycles:** N
- **Auto-fixed:** <list of checks that were auto-fixed, if any>
- **Escalated:** <list of checks escalated to user, if any>
- **Still failing:** <list, if any>
```

### Final report

```
CI Watch complete.

Result: All checks passing (after N fix cycles) / Some checks still failing
PR: <PR URL>

Fixed:
- <check>: <what was fixed> (cycle N)

Still failing:
- <check>: <reason>
```

## Standalone Usage

When invoked directly (`/n1:n1-ci` or `/n1:n1-ci #123`):
- Works without N1 memory files — developer agent uses only the diff and failure logs
- Same flow as above, but skip memory file reads if `$N1_HOME/memory/` doesn't exist
- Skip overview.md update if no memory directory

## Integration

**Called by:**
- **n1-start** — as step 11 (CI watch) after PR creation
- **Standalone** — `/n1:n1-ci` or `/n1:n1-ci #123`

**Invokes:**
- n1 agent: **developer** — CI failure fix cycle
