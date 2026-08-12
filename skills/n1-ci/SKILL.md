---
name: n1-ci
description: "Monitor CI checks after PR creation. Auto-fixes failures via developer agent, escalates to user after max attempts. Usage: /n1:n1-ci or /n1:n1-ci #123"
argument-hint: "[PR#]"
model: sonnet
effort: low
---

# N1 CI Watch & Fix

## Overview

Monitor CI checks on a PR, classify failures, and delegate fixes to the developer agent. User involvement only when max fix attempts exhausted or unknown check below confidence threshold.

**Announce at start:** "I'm using the n1-ci skill to monitor CI checks."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If empty — N1 not configured; warn the user. Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

## Prerequisites

```bash
gh auth status
```

Not authenticated → "Run `gh auth login` first." **STOP.**

## Step 1: Resolve PR Number

- **Argument** (`#123` or `123`): strip `#`, use directly.
- **No argument:** `gh pr view --json number,url,headRefName --jq '.number'`. No PR found → "No open PR found. Create one first or specify: `/n1:n1-ci #123`" **STOP.**

Capture PR number and URL.

## Step 2: Read CI Check Config

From config:
- `n1_config_val '.ciChecks.maxFixAttempts'` — default: `3`
- `n1_config_val '.ciChecks.confidenceThreshold'` — default: `0.7`
- `categories` — default: built-in map below

If `ciChecks.enabled` is explicitly `false` → "CI checks are disabled." **STOP.**

**Default categories** (when config has no `ciChecks.categories`):

| Category | Patterns | Behavior |
|----------|----------|----------|
| lint | lint, eslint, prettier, format, style, biome | auto-fix |
| typecheck | typecheck, tsc, mypy, type-check, pyright | auto-fix |
| test | test, jest, pytest, spec, vitest, mocha | auto-fix |
| build | build, compile, webpack, vite, esbuild | auto-fix |
| security | security, snyk, dependabot, codeql, sast | auto-fix |
| infra | timeout, runner, infrastructure | auto-fix |

## Step 3: Poll for CI Checks

> **Polling discipline:** Each `gh pr checks` poll is a **separate shell command**. NEVER combine into a bash loop. `sleep 30` between polls as a standalone command. Every poll result must be visible in reasoning context.

### Phase 1 — Wait for registration (up to 15 min)

1. `sleep 15` (initial delay).
2. `gh pr checks <PR#> --json name,state,conclusion,detailsUrl` — separate command.
3. Empty/no checks → `sleep 30`, re-poll (step 2).
4. Nothing after 15 min → "No CI checks appeared after 15 minutes." **STOP.**
5. Checks appear → Phase 2.

### Phase 2 — Poll until resolution (up to 30 min)

Poll via `lib/poll.sh` (internal 30s loop, 8-minute chunks):

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/poll.sh"
n1_wait_ci_checks <PR#> <remaining-minutes>
```

Re-invoke while `pending` and budget remains:
- `green` → **Step 4** (all green)
- `red` → run `gh pr checks <PR#> --json name,state,conclusion,detailsUrl` to enumerate failures, apply Phase 3 grace (up to 2 more `n1_wait_ci_checks` calls, `<max-minutes>` = 1), then **Step 4**
- `pending` at budget exhaustion → report pending checks, ask "Wait longer or skip?" **STOP.**

### Phase 3 — Failure grace (max 60s)

Once failure detected but other checks still pending:
1. Log: `"Failure detected. Waiting up to 60s for remaining checks."`
2. Up to 2 more polls (`sleep 30` + `gh pr checks` each — individual commands).
3. After 2 grace polls OR all completed → **Step 4** with current results.

## Step 4: Evaluate Results

All checks `conclusion: SUCCESS`/`NEUTRAL`/`SKIPPED`:
- Report "All CI checks passed."
- **Finish chaining (pipeline only):** when invoked from n1-start AND `finishWork.enabled` is `true`, continue into n1:n1-finish. Standalone runs never chain. Never chain into release.
- Go to **Step 7**.

Any `conclusion: FAILURE` → collect failures, go to **Step 5**.

## Step 5: Classify Failures

Match each failed check `name` against category patterns (case-insensitive substring, first match wins). No match → `unknown`.

**Per-category behavior:**
- `auto-fix` → developer agent
- `escalate` → skip developer, ask user immediately
- `skip` → ignore
- `unknown` → developer agent with confidence assessment (Step 5b)

### Step 5a: Fetch Failed Run Logs

Extract run ID from `detailsUrl` (`/actions/runs/<run-id>/...`):

```bash
gh run view <run-id> --log-failed 2>&1 | head -500
```

### Step 5b: Unknown Category Confidence Check

After developer returns for `unknown` checks:
- confidence >= `confidenceThreshold` → accept fix
- confidence < threshold → present to user with logs and analysis:
  "1 — Accept fix / 2 — Provide guidance / 3 — Skip this check"

## Step 6: Fix Cycle

**Batch all fixable failures** into one developer agent spawn. Resolve model for `developer`.

Pass: failed checks with categories, `--log-failed` output per check, `git diff $(git merge-base origin/<default-branch> HEAD)..HEAD`, memory files (`plan.md`, `implementation.md`) if available. Scratch-artifact policy: throwaway benchmarks/spikes go under `$N1_HOME/scratch/{benchmarks,tests}/` (gitignored), never in the repo test suite.

**Developer instructions:**

```
You are fixing CI failures on an open pull request. For each failed check:
1. Read the failure logs carefully
2. Identify the root cause in the codebase
3. Implement the minimal fix
4. Run relevant local checks if possible (e.g., lint, typecheck, test commands)

For "unknown" category checks: include a confidence assessment (0.0-1.0).

Commit all fixes with descriptive messages. Push to the PR branch after committing.

Output format:
## CI Fixes Applied
### Check: <check name> (<category>)
- **Root cause:** <cause>
- **Fix:** <change>
- **Files:** <modified files>
- **Confidence:** <0.0-1.0> (unknown category only)
## Summary
- Checks fixed: N/M
- Commits: <list>
```

**After developer returns:**
1. Handle `unknown` fixes below threshold (Step 5b flow)
2. Push if developer didn't: `git push`
3. ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "ci_fix_cycle"
   ```
4. `ci_fix_cycle` < `maxFixAttempts` → back to **Step 3**
5. `ci_fix_cycle` >= `maxFixAttempts` → **Step 6b**

### Step 6b: Max Attempts Exhausted

Present remaining failures and fix history, then offer:
1. Provide guidance → spawn developer with guidance, increment max by 1 (hard ceiling: 2x`maxFixAttempts`), log extension, back to Step 3
2. Skip CI → Step 7 with failing status
3. Fix manually → wait for "continue", back to Step 3 (reset counter)

## Step 7: Report & Memory Update

### Update overview.md (if memory exists):
```markdown
## CI Status
- **Result:** PASS / FAIL (with N fix cycles)
- **Fix cycles:** N
- **Auto-fixed:** <checks>
- **Escalated:** <checks>
- **Still failing:** <checks>
```

### Final report:
```
CI Watch complete.
Result: All checks passing (after N fix cycles) / Some checks still failing
PR: <PR URL>
Fixed:
- <check>: <fix> (cycle N)
Still failing:
- <check>: <reason>
```

## Standalone Usage

Works without N1 memory — developer uses only diff and logs. Skip memory reads/updates when `$N1_HOME/memory/` absent.

## Integration

**Called by:** n1-start (step 11, CI watch after PR creation), standalone `/n1:n1-ci` or `/n1:n1-ci #123`
**Invokes:** n1 agent: developer (CI fix cycle)
