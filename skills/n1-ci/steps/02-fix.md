<!-- Purpose: Classify failures, fix cycle, report and memory update, standalone usage, integration (Steps 5-7). -->

## Step 5: Classify Failures

Match each failed check `name` against category patterns (case-insensitive substring, first match wins). No match → `unknown`.

**Per-category behavior:**
- `auto-fix` → developer agent
- `escalate` → skip developer, ask user immediately
- `skip` → ignore
- `unknown` → developer agent with confidence assessment (Step 5b)

### Step 5a: Collect Run IDs (no log fetching here)

Extract the run ID from each failed check's `detailsUrl` (`/actions/runs/<run-id>/...`) and pair it with the check name and category. Do NOT run `gh run view --log-failed` in the orchestrator — failure logs are large and pull the orchestrator into diagnosing and fixing the failure itself. The developer agent fetches logs (Step 6).

Only when a check is classified `escalate` (needs the user) may the orchestrator run `gh run view <run-id> --log-failed 2>&1 | tail -60` to show the user the failure excerpt.

### Step 5b: Unknown Category Confidence Check

After developer returns for `unknown` checks:
- confidence >= `confidenceThreshold` → accept fix
- confidence < threshold → present to user with logs and analysis:
  "1 — Accept fix / 2 — Provide guidance / 3 — Skip this check"

## Step 6: Fix Cycle

> **ORCHESTRATOR GUARDRAIL (n1-ci): the orchestrator NEVER edits files, runs formatters, linters, compilers, package managers, or lock-file tools, and NEVER commits or pushes in this skill — regardless of how trivial the failure looks (a one-line lint fix, a lock-file regeneration, a CRLF issue). Every remediation, including "obvious" ones, goes through the developer spawn below. The orchestrator's only git actions in n1-ci are `git push` in "After developer returns" step 2 and read-only inspection (`git log`, `git status`, `gh pr checks`).**

**Batch all fixable failures** into one developer agent spawn. Resolve model for `developer`.

Pass: failed checks with categories and run IDs (from Step 5a), the PR branch name, the main checkout path, `git diff $(git merge-base origin/<default-branch> HEAD)..HEAD`, memory files (`plan.md`, `implementation.md`) if available. Scratch-artifact policy: throwaway benchmarks/spikes go under `$N1_HOME/scratch/{benchmarks,tests}/` (gitignored), never in the repo test suite.

**Developer instructions:**

```
You are fixing CI failures on an open pull request.

Workspace: The worktree may already have been removed after PR creation. Resolve your working directory first:
- If `<worktree path>` exists, `cd` there.
- Otherwise, in `<main checkout path>`: `git fetch origin <branch> && git checkout <branch>` (create a fresh worktree with `git worktree add <main-checkout>/<worktree-root>/<ID> <branch>` if the main checkout has uncommitted changes).
Never work on the default branch.

For each failed check (name, category, run ID):
1. Fetch the logs yourself: `gh run view <run-id> --log-failed 2>&1 | head -500`
2. Identify the root cause in the codebase
3. Decide: is the failure caused by THIS branch's changes, or is it pre-existing / CI-side (e.g. lock drift that also fails on the default branch, flaky infra)? Check with `gh run list --branch <default-branch> --limit 5` when unsure.
   - Branch-caused → implement the minimal fix.
   - Pre-existing / CI-side → do NOT paper over it with unrelated changes; report it as `NOT_BRANCH_CAUSED` with evidence so the orchestrator can escalate.
4. Run the relevant local check (lint, typecheck, test command) if possible before committing.

For "unknown" category checks: include a confidence assessment (0.0-1.0).

Commit all fixes with descriptive messages. Push to the PR branch after committing.

Output format:
## CI Fixes Applied
### Check: <check name> (<category>)
- **Root cause:** <cause>
- **Fix:** <change> | NOT_BRANCH_CAUSED: <evidence>
- **Files:** <modified files>
- **Confidence:** <0.0-1.0> (unknown category only)
## Summary
- Checks fixed: N/M
- Not branch-caused: <list or none>
- Commits: <list>
```

**After developer returns:**
1. Handle `unknown` fixes below threshold (Step 5b flow)
2. Any check reported `NOT_BRANCH_CAUSED` → treat as `escalate`: present the developer's evidence to the user with "1 — Accept as pre-existing and continue / 2 — Provide guidance / 3 — Abort". Do not attempt to fix it yourself. Do not count it toward `ci_fix_cycle`.
3. Push if developer didn't: `git push`
4. ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/frontmatter.sh"
   n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "ci_fix_cycle"
   ```
5. `ci_fix_cycle` < `maxFixAttempts` → back to **Step 3** (in 01-monitor.md)
6. `ci_fix_cycle` >= `maxFixAttempts` → **Step 6b**

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
