<!-- Purpose: Prerequisites, resolve PR, read CI config, poll for CI checks, evaluate results (Steps 1-4). -->

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
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/poll.sh"
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
- Go to **Step 7** (in 02-fix.md).

Any `conclusion: FAILURE` → collect failures, go to **Step 5** (in 02-fix.md).
