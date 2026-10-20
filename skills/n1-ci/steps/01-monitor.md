<!-- Purpose: Prerequisites, resolve PR, read CI config, poll for CI checks, evaluate results (Steps 1-4). -->

## Prerequisites

```bash
gh auth status
```

Not authenticated → "Run `gh auth login` first." **STOP.**

## Step 1: Resolve PR Number

- **Argument** (`#123` or `123`): strip `#`, use directly.
- **No argument:** `gh pr view --json number,url,headRefName --jq '.number'`. No PR found → "No open PR found. Create one first or specify: `/n1:n1-ci #123`" **STOP.**

Capture PR number and URL. Record the PR head at run start for the PR body reconcile — the run-start contract in `<N1_ROOT>/references/reconcile-pr-body.md`:

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<PR number>"
mkdir -p "$N1_HOME/scratch"
find "$N1_HOME/scratch" -maxdepth 1 -name 'reconcile-start-*' -mtime +1 -delete 2>/dev/null
RECONCILE_START_FILE=$(mktemp "$N1_HOME/scratch/reconcile-start-$PR_NUMBER.XXXXXX")
gh pr view "$PR_NUMBER" --json headRefOid --jq .headRefOid > "$RECONCILE_START_FILE" 2>/dev/null || true
echo "reconcile:start file=$RECONCILE_START_FILE"
```

Carry `$RECONCILE_START_FILE` forward into Step 4 / Step 7a (in 02-fix.md), the same way `<D>` is carried from `reconcile:run dir=`.

## Step 2: Read CI Check Config

From config:
- `MAX_FIX` — fixed start value `3` (raised only by Step 6b, ceiling `6`); `ci_fix_cycle` counter lives in overview.md
- `confidenceThreshold` — fixed: `0.7`
- `categories` — default: built-in map below

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
4. Nothing after 15 min → run **Step 7a** (Reconcile PR Body, in 02-fix.md) before stopping — a prior fix cycle may already have pushed, then "No CI checks appeared after 15 minutes." **STOP.**
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
- `pending` at budget exhaustion → run **Step 7a** (Reconcile PR Body, in 02-fix.md) before stopping — a prior fix cycle may already have pushed, then report pending checks, ask "Wait longer or skip?" **STOP.**

### Phase 3 — Failure grace (max 60s)

Once failure detected but other checks still pending:
1. Log: `"Failure detected. Waiting up to 60s for remaining checks."`
2. Up to 2 more polls (`sleep 30` + `gh pr checks` each — individual commands).
3. After 2 grace polls OR all completed → **Step 4** with current results.

## Step 4: Evaluate Results

All checks `conclusion: SUCCESS`/`NEUTRAL`/`SKIPPED`:
- Report "All CI checks passed."
- Run **Step 7a** (in 02-fix.md) now, before any finish chaining. n1-finish reads the PR body's Deployment Actions, so the body must match the pushed diff first. The later pass through Step 7 prints `reconcile:skip`.
- **Finish chaining:** none. N1 never merges a PR; the human merges, then runs `/n1:n1-finish`. Never chain into n1-finish or release.
- Go to **Step 7** (in 02-fix.md).

Any `conclusion: FAILURE` → collect failures, go to **Step 5** (in 02-fix.md).
