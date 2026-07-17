---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--step <name>]"
model: sonnet
effort: medium
---

# N1 Core Orchestrator

## Overview

Single entry point for all task work. Accepts a ticket ID or a brain dump, then orchestrates the full development cycle using specialized agent personas: product-analyst, solution-architect, developer, qa-engineer, code-reviewer, security-reviewer, and tech-writer.

**Announce at start:** "I'm using the n1-start skill to work on this task."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run, before any config or memory access. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured (see Prerequisites below). If relative (starts with `.`) — backward compat for unmigrated projects.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/<ID>/`. All telemetry paths use `$N1_HOME/memory/<ID>/telemetry/`.

## Prerequisites

Read `$N1_HOME/config.json` (resolved via N1_HOME Resolution above):

- **If N1_HOME could not be resolved** (no `git config n1.home` and no `.n1/n1.config.json`): Tell the user: "N1 is not configured for this project. Would you like to run `/n1:n1-init` to set it up?" **Wait for response.** If yes — invoke `/n1:n1-init`, then resume. If no — **STOP.**
- **If resolved:** Continue.

## Telemetry Initialization

Read `telemetry.enabled` from `$N1_HOME/config.json` (default `false` if absent or if `telemetry` block is missing).

**If `telemetry.enabled` is `true`:**
1. Read plugin version:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   N1_VERSION=$(n1_config_val '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
   ```
2. Generate run ID — **preserve an existing `N1_RUN_ID` environment value** (n1-loop provides one per step-mode invocation; escalation request/response correlation depends on echoing it back exactly):
   ```bash
   N1_RUN_ID="${N1_RUN_ID:-$(date -u +n1-run-%Y%m%dT%H%M%SZ)}"
   ```
3. Create per-ticket telemetry directories:
   ```bash
   mkdir -p "${N1_HOME}/memory/$ID/telemetry/raw/steps" "${N1_HOME}/memory/$ID/telemetry/raw/agents" "${N1_HOME}/memory/$ID/telemetry/runs"
   ```
4. Write JSON lock file:
   ```bash
   echo '{"run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'"}' > "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
   ```

Where `$ID` is the ticket ID or provisional slug — the same `<ID>` used for the memory directory. The telemetry directory is created at the same moment as the memory directory (using provisional ID if the final ID is not yet known). Since telemetry lives inside `$N1_HOME/memory/<ID>/`, the existing **Reconcile Memory ID & Branch** procedure moves it automatically when the ID changes.

**If `telemetry.enabled` is `false`:** Skip all telemetry shell calls throughout the pipeline. Do not generate `N1_RUN_ID`, do not write lock files, do not emit step markers. The hooks will also exit silently (no lock file = no-op).

Throughout the pipeline, `N1_RUN_ID` and `N1_VERSION` are passed to each telemetry shell call explicitly — do not rely on them persisting between shell calls. (In step mode, n1-loop DOES set `N1_RUN_ID` in the session environment — that value is authoritative and must be reused, never regenerated.)

## Input Parsing

The user provides one of:
- **Ticket ID** — matches the tracker prefix from config (e.g., `TRID-510`, `PROJ-42`)
- **Error tracker URL** — matches `errorTracking.urlPattern` from config (e.g., `https://myorg.sentry.io/issues/12345`)
- **File path** — a path to a file containing requirements
- **Brain dump** — free-text description of what needs to be built
- **Resume** — ticket ID or slug where memory already exists

### Detect input type:

Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_detect_input_type "<user-input>" "$N1_HOME/config.json"
```

Returns exactly one of: `ticket`, `error-tracker`, `file`, `braindump`.

### Error tracker URL parsing:

When error tracker mode is detected, extract the issue ID from the URL:
- Match the last numeric segment after `/issues/` in the URL path (e.g., `https://myorg.sentry.io/issues/12345` → `12345`)
- If parsing fails (no numeric ID found), fall back to **Brain dump mode** with the URL as text content and warn: "Could not parse issue ID from URL — treating as brain dump."
- Store the original URL for later use in ticket.md and tracker ticket creation.
- The provisional memory ID is `sentry-<issueId>` (e.g., `sentry-12345`). The `sentry-` prefix avoids collision with numeric ticket IDs.

## Step Mode

When the input contains `--step <name>`, n1-start executes ONLY the named step and exits with a structured result. This enables the n1-loop step-per-session execution model where each step gets a fresh context window.

### Step argument detection

After resolving N1_HOME and loading config, check if the input contains `--step`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
step_result=$(n1_parse_step_arg "<raw-input>")
step_exit=$?
```

**Three outcomes:**
- `exit 0` — `--step` present and valid. Parse the result: `step_name` and `id_part` are extracted from the `step=<name> id=<rest>` output. Enter step mode.
- `exit 1` — `--step` absent. Continue with full pipeline mode (existing behavior, no changes).
- `exit 2` — `--step` present but invalid name. Emit error result and stop:
  ```bash
  n1_emit_step_result "<invalid-name>" "error" "null" "null" ',"error":"Invalid step name"'
  ```

### Step mode dispatch

When step mode is active:

1. **Set `<ID>`** from the parsed `id_part`. This is always a ticket ID or slug — brain-dump text is not supported in step mode (the `ticket` step with brain-dump input should be run in full pipeline mode for the first invocation; subsequent steps use the resolved ID).

2. **Read overview.md** — load `$N1_HOME/memory/<ID>/overview.md` for current state and loop counters:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   current_step=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "step")
   qa_fix_cycle=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
   review_fix_cycle=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
   clean_passes=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "clean_passes")
   local_test_fix_cycle=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "local_test_fix_cycle")
   ```
   Exception: if the requested step is `ticket` and overview.md does not exist, this is a fresh start — skip the overview read and proceed to the ticket step directly.

3. **Ensure Worktree (conditional)** — Read `type` from overview.md frontmatter (if overview.md exists for this `<ID>`):
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
   TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md" 2>/dev/null || echo "")
   ```
   Skip Ensure Worktree when `TYPE` is `"investigation"` or when `step_name` is `"ticket"` (the ticket step fragment handles its own workspace isolation after investigation detection). Otherwise, run the **Ensure Worktree(`<ID>`)** procedure (Step Mode, see Workspace Isolation above).

4. **Verify dependencies:**
   ```bash
   deps=$(n1_step_dependencies "$step_name")
   if [ -n "$deps" ]; then
       n1_verify_dependencies "$N1_HOME/memory/$ID" $deps
   fi
   ```
   If verification fails, emit error result:
   ```bash
   n1_emit_step_result "$step_name" "error" "null" "null" ',"error":"Missing dependency files: <list>"'
   ```
   and stop.

5. **Check config gates** — certain steps are gated by config. If the gate is closed, emit `skip` and the appropriate `next_step` (see Step Mode Routing below):
   - `estimation`: gated by `estimation.enabled` (default `false`)
   - `plan-review`: gated by `planReview.reviewPlan` (default `true`)
   - `local-testing`: gated by `localTesting.enabled` (default `false`)
   - `ci`: gated by `ciChecks.enabled` (default `true`)
   - `finish`: gated by `finishWork.enabled` (default `false`)

6. **Telemetry init** — if telemetry is enabled, initialize `N1_RUN_ID` and write the lock file (same as full pipeline Telemetry Initialization). Each step-mode invocation gets its own run ID — **supplied by n1-loop via the `N1_RUN_ID` environment variable; reuse it, never regenerate it** (escalation correlation matches on it).

7. **Execute the step** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/<step_name>.md` (the fragment file named after the step). The step execution logic is identical to full pipeline mode — same agent spawning, same output handling, same overview.md updates. The `brainstorm` fragment itself routes step mode to `autonomous-brainstorm.md`, as before.

8. **After step execution** — do NOT proceed to the next step. Instead, compute the `next_step` from the Step Mode Routing table and emit the structured result — you MUST actually run the bash helper (it writes `step-result.json` AND prints the line); merely typing an `N1_STEP_RESULT:` line in your response text is NOT sufficient:
   ```bash
   n1_emit_step_result "$step_name" "<outcome>" "<next_step>" "<loop_counter_or_null>"
   ```
   Then stop.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name> [context]
```

The optional `context` parameter enables signal-driven model tiering (e.g., `n1_resolve_model developer fix`). Resolution chain: config override > signal-driven triggers > profile step_overrides > agent frontmatter default.

## Orchestrator Output Discipline

Between steps, emit ONLY: the step name being dispatched, the agent being spawned (with model), and any routing decision with its reason. Do not summarize step outputs, re-describe the task, or narrate intermediate state. Memory files carry context between steps — the orchestrator does not need to.

## Effort-Level Routing

After resolving the workflow type, read the `orchestrator_effort` field from the type's pipeline.json entry. If the type has a `tier_override` map and the current tier matches, use the override value instead. This controls the orchestrator's reasoning depth for the run:

```bash
# Read from pipeline.json after type resolution
EFFORT=$(jq -r ".types[\"$TYPE\"].orchestrator_effort // \"high\"" "${CLAUDE_PLUGIN_ROOT}/pipeline.json")
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier" 2>/dev/null || echo "")
if [ -n "$TIER" ]; then
    TIER_EFFORT=$(jq -r ".types[\"$TYPE\"].tier_override[\"$TIER\"] // empty" "${CLAUDE_PLUGIN_ROOT}/pipeline.json" 2>/dev/null || true)
    [ -n "$TIER_EFFORT" ] && EFFORT="$TIER_EFFORT"
fi
```

## Workspace Isolation

N1 uses two isolation modes, determined by invocation:

| Invocation | Isolation | Rationale |
|---|---|---|
| `n1-start <ID>` (full pipeline) | **Branch** in current checkout | Interactive — user and IDE stay in familiar territory |
| `n1-start <ID> --step <name>` | **Worktree** at `.claude/worktrees/<ID>/` | Automated — fresh context per step, no human navigating |

Both procedures are **idempotent** — safe to call again on resume. They are called at each ID-resolution point (see Step 1 and Memory Check).

**PROCEDURE: Ensure Working Branch (`<ID>`)**

Used by full-pipeline `n1-start` (no `--step`). Operates in the current checkout.

1. Compute the target branch name from `git.branchPattern` (config) + `<ID>`:
   - `{prefix}-{id}` → e.g. `TRID-510`
   - `{id}` → e.g. `510`
   - `{slug}` or `feature/{slug}` → e.g. `feature/csv-export-users`

   Sanitize for git ref validity: lowercase the slug, replace spaces and illegal characters with `-`, collapse repeats, trim leading/trailing `-`. Ticket IDs are already ref-safe; only slugs need sanitizing.

2. Read current state:
   ```bash
   CURRENT=$(git branch --show-current)
   DEFAULT=<git.defaultBranch from config>
   ```

3. Check for uncommitted changes:
   ```bash
   DIRTY=$(git status --porcelain)
   ```

4. Decide:
   - **`CURRENT` == `TARGET`** → already on it. Reuse silently.
   - **A local branch named `TARGET` already exists AND `DIRTY` is empty** → `git checkout <TARGET>`.
   - **A local branch named `TARGET` already exists AND `DIRTY` is non-empty** → prompt (dirty working tree prompt below).
   - **`CURRENT` == `DEFAULT` AND `DIRTY` is empty** → `git checkout -b <TARGET>`.
   - **`CURRENT` == `DEFAULT` AND `DIRTY` is non-empty** → prompt (dirty working tree prompt below).
   - **`CURRENT` is some OTHER branch AND `DIRTY` is empty** → prompt (foreign branch prompt below).
   - **`CURRENT` is some OTHER branch AND `DIRTY` is non-empty** → prompt (combined prompt below).

5. **Dirty working tree prompt** (when on `DEFAULT` or `TARGET` exists, with uncommitted changes):
   ```
   You have uncommitted changes. How should I proceed?
   1 — Stash changes and switch to '<TARGET>' (run `git stash pop` to restore later)
   2 — Carry changes to '<TARGET>' (switch with dirty tree)
   3 — Abort — commit or stash manually first
   ```
   If option 1: run `git stash push -m "n1: stashed before switching to <TARGET>"`, then proceed with the branch switch. Report the stash name so the user can restore it: "Stashed uncommitted changes. Run `git stash pop` when done."

6. **Foreign branch prompt** (when on a branch that is neither `TARGET` nor `DEFAULT`, clean tree):
   ```
   You're on branch '<CURRENT>', not the default ('<DEFAULT>').
   1 — Create '<TARGET>' from here
   2 — Switch to '<DEFAULT>' and branch '<TARGET>' from there
   3 — Keep working on '<CURRENT>'
   ```

7. **Combined prompt** (foreign branch + dirty):
   ```
   You're on branch '<CURRENT>' (not '<DEFAULT>') and have uncommitted changes.
   1 — Stash changes, switch to '<DEFAULT>', branch '<TARGET>' from there (run `git stash pop` to restore later)
   2 — Create '<TARGET>' from '<CURRENT>', carrying uncommitted changes
   3 — Abort — handle manually
   ```
   If option 1: same stash procedure as the dirty working tree prompt above.

8. **Record the review base (creation paths only, idempotent):** on any path that CREATES `<TARGET>` (`git checkout -b`), record the branch point immediately — before any commits land — so later review steps diff against it instead of `git.defaultBranch` (which balloons when the branch started from a non-default branch):
   ```bash
   mkdir -p "$N1_HOME/memory/<ID>"
   BP_FILE="$N1_HOME/memory/<ID>/branch-point"
   [ -f "$BP_FILE" ] || git rev-parse HEAD > "$BP_FILE"
   ```
   On reuse paths (branch already existed), do NOT write the file — review falls back to a merge-base against the default branch.

9. Report: "Working on branch `<TARGET>`."

No `fetch`/`pull` is performed — the branch is created from the local default branch's current HEAD. The user owns keeping their local default up to date.

**PROCEDURE: Ensure Worktree (`<ID>`) — Step Mode**

Used only by `n1-start --step`. Creates or reattaches a worktree at `<main-checkout>/.claude/worktrees/<ID>/`.

1. **Check if `N1_HOME` is absolute** (starts with `/`, `~`, or a drive letter like `C:\`):
   - **If relative** (starts with `.`, e.g. `.n1`) → worktrees cannot be used because config and memory paths would resolve inside the worktree instead of the main checkout. Emit error result and stop:
     ```bash
     n1_emit_step_result "$step_name" "error" "null" "null" ',"error":"Step mode requires externalized state (absolute N1_HOME). Run n1-init to migrate."'
     ```
   - **If absolute** → continue with worktree creation.

2. Compute the target branch name from `git.branchPattern` (config) + `<ID>` (same sanitization as Ensure Working Branch above).

2. Check if a worktree for this branch already exists:
   ```bash
   git worktree list --porcelain
   ```
   Parse the porcelain output: each entry has a `worktree <path>` line followed by `branch refs/heads/<name>`. Look for an entry whose `branch` line matches `refs/heads/<TARGET>`.

3. **If worktree exists** → extract its path from the `worktree` line preceding the matching `branch` line. Store it as `WORKTREE_PATH`. Report: "Resuming worktree at `<WORKTREE_PATH>`."

4. **If worktree does not exist:**
   a. Compute the main checkout root:
      ```bash
      MAIN_CHECKOUT=$(git rev-parse --show-toplevel)
      WORKTREE_PATH="$MAIN_CHECKOUT/.claude/worktrees/<ID>"
      ```
   b. Create the branch if needed (idempotent — fails silently if already exists), and record the review base at creation:
      ```bash
      DEFAULT=<git.defaultBranch from config>
      git branch <TARGET> $DEFAULT 2>/dev/null || true
      BP_FILE="$N1_HOME/memory/<ID>/branch-point"
      mkdir -p "$N1_HOME/memory/<ID>"
      [ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$BP_FILE"
      ```
   c. Check if the main checkout is currently on the target branch (this blocks `git worktree add`):
      ```bash
      CURRENT=$(git branch --show-current)
      ```
      If `CURRENT == TARGET`: switch the main checkout away first: `git checkout $DEFAULT`.
   d. Create the worktree:
      ```bash
      git worktree add "$WORKTREE_PATH" <TARGET>
      ```
      If this fails because the directory already exists (e.g., from a crashed prior run), manually remove `<main-checkout>/.claude/worktrees/<ID>/` or run `/n1:n1-clean` to clean up stale worktrees, then retry.
   e. Report: "Working in worktree `$WORKTREE_PATH` on branch `<TARGET>`."

5. Store `WORKTREE_PATH` for use by subsequent pipeline steps.

No `fetch`/`pull` is performed — the branch is created from the local default branch's current HEAD.

**PROCEDURE: Ensure Dependencies (`<ID>`) — Step Mode only**

Idempotent, marker-guarded dependency install. Called by the first code-executing
step (implementation) and defensively by qa/review/local-testing. Full-pipeline
(branch) mode never calls this — its checkout already has dependencies.

1. **Step-mode check.** If this run is NOT step mode (no worktree for `<ID>`), return
   immediately — do nothing.
2. **Config check.** Read `worktree.setup` from config:
   ```bash
   SETUP=$(n1_config_val '.worktree.setup')
   ```
   If `SETUP` is empty, `null`, or absent → return (nothing to install).
3. **Marker check.** Resolve `WORKTREE_PATH` for `<ID>` (from `git worktree list`, same
   parse as `Ensure Worktree`). If `<WORKTREE_PATH>/.n1-deps-installed` exists → return
   (already installed for this worktree).
4. **Install.**
   ```bash
   cd "$WORKTREE_PATH" && eval "$SETUP"
   ```
   - **On success:** `touch "$WORKTREE_PATH/.n1-deps-installed"`; report
     "Dependencies installed via `$SETUP`."
   - **On failure:** do NOT create the marker (so the next run / a Retry re-attempts).
     Report the command's stderr and **escalate**:
     - **Step mode:** write `$N1_HOME/memory/<ID>/escalation/request.json`:
       ```json
       {
         "run_id": "<value of the N1_RUN_ID environment variable>",
         "step": "<current step name>",
         "questions": [{
           "id": "worktree_setup_failure",
           "text": "<one-paragraph description of the setup failure with stderr>",
           "options": ["Retry setup", "Skip and continue anyway", "Abort: stop the pipeline"],
           "recommendation": "Retry setup — a transient install failure usually clears on retry",
           "context": "<setup command, stderr excerpt, worktree path>"
         }]
       }
       ```
       Then run via Bash:
       ```bash
       source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
       n1_emit_step_result "<current step name>" "escalation" "null" "null"
       ```
       and STOP.
     - **On re-run** (`response.json` present and `run_id` matches `N1_RUN_ID`):
       - "Retry setup" → re-run step 4.
       - "Skip and continue anyway" → record in overview `## Escalations`
         ("worktree setup skipped by user"), do NOT create the marker, and continue the step.
       - "Abort" → record it and emit `outcome: "error"` with `next_step: null`.

**PROCEDURE: Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)**

Heals state that leaked under a provisional slug before the final `<ID>` was known (e.g. if the orchestrator drifted into the ticket-less path after a "Yes"). **Idempotent** — safe to call when nothing leaked. `<oldId>` is the deterministically-computed provisional slug; `<newId>` is the final ID.

1. **If `<oldId>` == `<newId>`** → return (no-op).
2. **Memory move:** if `$N1_HOME/memory/<oldId>/` exists AND `$N1_HOME/memory/<newId>/` does NOT → filesystem-move the directory `<oldId>/` → `<newId>/` (`$N1_HOME/` is gitignored or outside the repo, so a plain `mv` / `Move-Item`, NOT `git mv`). If `$N1_HOME/memory/<newId>/` already exists, skip the move and report — the `<newId>` memory is authoritative (resume/collision guard).
3. **Frontmatter fix:** if `$N1_HOME/memory/<newId>/overview.md` exists (true only when an overview was already written under the slug and just moved — in the clean path it does not exist yet), rewrite its `ticket: <oldId>` → `ticket: <newId>` and its `# <oldId>: <Title>` heading → `# <newId>: <Title>`.
4. **Branch rename:** compute `<oldBranch>` and `<newBranch>` from `git.branchPattern` (config). If a local branch `<oldBranch>` exists AND `<newBranch>` does NOT → `git branch -m <oldBranch> <newBranch>` (rename preserves commits; N1 has not pushed yet). If `<newBranch>` already exists, skip the rename.
5. **Worktree move (step mode only):** if `.claude/worktrees/<oldId>/` exists → compute `MAIN_CHECKOUT=$(git rev-parse --show-toplevel)` and run `git worktree move $MAIN_CHECKOUT/.claude/worktrees/<oldId> $MAIN_CHECKOUT/.claude/worktrees/<newId>`. In branch mode (no `--step`), no worktree exists — skip silently.
6. Report: "Migrated memory + branch `<oldId>` → `<newId>`." (append "+ worktree" if a worktree was moved)

### Agent Working Directory

In step mode, when `WORKTREE_PATH` is set, pass this directive to every agent spawn that reads or modifies source code (qa-engineer, code-reviewer, security-reviewer, developer in fix cycles, tech-writer, solution-architect for local testing):

> Work in the worktree directory at `WORKTREE_PATH`. All file read/write/edit/grep/glob operations and all git/bash commands that touch the codebase MUST target files within this directory, not the main checkout. Memory files remain at `$N1_HOME/memory/<ID>/` (unchanged).

In branch mode (full pipeline, no `--step`), omit this directive — agents work in the current directory on the feature branch.

### Context Assembly Order (step mode)

In step/loop mode, each step is a fresh session that reloads persona + config + memory, so prompt-cache hits depend on a stable leading prefix. When assembling any agent spawn's context in step mode, order it **stable-prefix-first, volatile-last**:

1. **Stable prefix (cache-eligible):** agent persona/definition, the tracker-routing block, and the config snapshot — content that is identical across loop sessions for this project.
2. **Volatile suffix (do NOT rely on caching):** per-ticket memory files (`ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md`, `implementation.md`, `qa.md`, `review.md`), diffs, and tool results — content that changes every step.

Do not attempt to cache volatile memory files; interleaving them into the prefix defeats caching and can increase latency. In branch mode (full pipeline) this ordering is a no-op — the session is continuous — but applying it uniformly is harmless.

## Memory Check (Resume Support)

Check if `$N1_HOME/memory/<input>/overview.md` exists:

- **If exists:** Read the overview frontmatter to determine current step. Also read the pipeline type:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
  ```
  When `TYPE` is `"investigation"`, the pipeline runs the shortened investigation flow (see Step 3b and Planning Need Routing below) — skip workspace isolation (no branch or worktree needed for investigation tasks). Otherwise, run the appropriate workspace isolation procedure: **Ensure Working Branch(`<ID>`)** in full pipeline mode, or **Ensure Worktree(`<ID>`)** in step mode (see Workspace Isolation above). This covers resuming from a session that ended without cleanup. Then resume from where work left off: read the dependency files for the current step (see dependency map below) and continue. **Also read the loop counters** (`qa_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, and `ci_fix_cycle` if present) so bounded loops resume at their true count, not zero (see Loop-Counter Durability below). Read each via:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
  ```
- **If not exists:** Fresh start. Create `$N1_HOME/memory/<ID>/` directory.

### Step dependency map

Step dependencies (the `reads`/`writes` for each of the 14 steps) are declared
in `${CLAUDE_PLUGIN_ROOT}/pipeline.json` under `steps[]`. **Read that file** to
determine which files a step depends on. The `reads` list is the **hard-dependency**
set enforced by the dependency-integrity guard; a step's fragment MAY additionally
read the optional/context inputs its own body specifies (e.g. implementation and qa
also use `plan.md`). No step blanket-reads the full history. The bash helper `n1_step_dependencies`
(in `lib/validation.sh`) mirrors the same `reads` values for the dependency
integrity guard below; a CI test keeps the two in parity.

### Loop-counter durability & crash-safe checkpointing

- **Loop counters live in overview frontmatter**, never only in orchestrator context: `qa_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle` (and `ci_fix_cycle`, owned by n1-ci). Increment them in the file as each loop turns and read them back on resume. A bound held only in context resets to zero on restart, silently defeating it.
- **Overview is the single source of truth for progress.** Each step writes its output file FIRST, then updates `step:`/checkbox in overview LAST. On resume, a step counts as done only if overview says so. If a crash lands between the two writes (output file exists but overview still points at the prior step), re-running is safe because every artifact write is a full overwrite — idempotent, never an append.

**Dependency integrity guard (applies to every step).** Before spawning a step's agent or sub-skill, run:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```

(Pass the declared dependency files for the current step — see table above.) If any dependency is missing or empty, the function prints the missing files to stderr and returns non-zero — **STOP and report** rather than proceeding with a degraded handoff. (`ticket.md` with no acceptance criteria is handled upstream by product-analyst and is not a hard stop.)

## Pipeline Steps

Step 3 (Brainstorm) is **INTERACTIVE in full pipeline mode only** — Superpowers handles user interaction during brainstorming. In step mode, the autonomous brainstormer runs headlessly with escalation-on-demand. Step 4 (Plan checkpoint) pauses for explicit plan approval when `requirePlanApproval` is enabled.

### Telemetry Step Markers

**If telemetry is enabled**, emit a step marker at the start and end of each pipeline step using the shared helper:

**Step start:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Step end:**
```bash
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" <N> "${N1_HOME}/memory/$ID/telemetry" completed_at=now outcome=<pass|fail|skip> loop_iteration=<N|null> metadata='<JSON>'
```

**Skipped steps** get a single call with `outcome=skip` (no separate start event needed).

Step numbering and names:

| step_number | step name | metadata fields |
|-------------|-----------|-----------------|
| 1 | `ticket` | `{}` (writes `tier` to overview.md frontmatter) |
| 2 | `analysis` | `{}` (may update `tier` in overview.md frontmatter) |
| 3 | `brainstorm` | `{"planning_need":"plan\|direct"}` |
| 4 | `plan` | `{}` |
| 5 | `plan-review` | `{"verdict":"CLEAN\|FIXED"}` |
| 6 | `estimation` | `{"tier":"XS\|S\|M\|L\|XL"}` |
| 7 | `implementation` | `{"execution_path":"direct|sdd"}` |
| 8 | `qa` | `{"loop_iteration":<N>}` |
| 9 | `review` | `{"findings_total":<N>,"findings_critical":<N>}` |
| 10 | `fix` | `{"loop_iteration":<N>}` |
| 11 | `local-testing` | `{}` |
| 12 | `pr` | `{}` |
| 13 | `ci` | `{}` |
| 14 | `finish` | `{}` |

**Naming note:** The overview.md frontmatter `tier:` field (values: `simple`/`standard`/`complex`) controls model/effort routing in n1-loop. The brainstorm step-result `planning_need` key (values: `plan`/`direct`) controls pipeline branching — whether a formal plan is needed. The estimation body line `**Complexity:** XS/S/M/L/XL` is delivery sizing. These three concepts are independent.

**Skipped steps** get a single event with `outcome: "skip"` (no separate start event needed). For example, if estimation is disabled: `{"step":"estimation","step_number":6,"completed_at":"...","outcome":"skip"}`.

Each step section in the pipeline below should emit its start marker before spawning agents and its end marker after updating overview.md.

### 1. REQUIREMENTS ANALYSIS

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/ticket.md`.

### 2. ANALYSIS

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/analysis.md`.

### 3. BRAINSTORM

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/brainstorm.md`.

### 3b. INVESTIGATION DELIVERABLE (investigation mode only)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/investigation-deliverable.md`.

This step only runs when `TYPE` is `"investigation"` (read from overview.md frontmatter via `n1_read_type "$N1_HOME/memory/$ID/overview.md"`). After this step, the pipeline terminates (no plan, implementation, QA, review, or PR steps).

### Estimation

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/estimation.md`.

### Planning Need Routing

**Investigation mode:** If `TYPE` is `"investigation"` (read from overview.md frontmatter via `n1_read_type`), skip planning need routing entirely — investigation tasks always proceed from brainstorm to the investigation-deliverable step. The brainstorm step's routing handles this via `pipeline.json`.

Read `planning_need` from the brainstorm step result (set by the brainstormer in Step 3). Route:
- `planning_need: plan` → Continue to **PLAN** (Step 4)
- `planning_need: direct` → Skip to **IMPLEMENT** (Step 5)

The orchestrator does NOT make its own judgment — the brainstormer already evaluated design sufficiency with analysis.md in context. The `planning_need` value is authoritative.

**If direct:** Before proceeding to IMPLEMENT, run the **Estimation** procedure (see above). Then continue to Step 5 (IMPLEMENT).

### 4. PLAN (plan path only)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/plan.md`.

### 4b. PLAN REVIEW (Cross-Context Review)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/plan-review.md`.

### 4c. Estimation (after plan)

Run the **Estimation** procedure (see Estimation section above). The `plan.md` file is available, providing maximum context for accurate classification.

### Plan Checkpoint (conditional)

Run `n1_config_val '.planReview.requirePlanApproval'` (default: `false`).

**If `planReview.requirePlanApproval` is `true`:**

Present the plan to the user for approval:
"Plan is ready at `$N1_HOME/memory/<ID>/plan.md`. Please review and approve before I proceed with implementation."

**Wait for explicit approval before continuing.**

**If `planReview.requirePlanApproval` is `false`:**

Proceed directly to implementation. Log: "Plan review passed — proceeding to implementation."

### 5. IMPLEMENT

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/implementation.md`.

### 6. QA

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/qa.md`.

### 7. REVIEW

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/review.md`.

### 8. FIX (if review failed)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/fix.md`.

### 9. LOCAL TESTING (conditional)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/local-testing.md`.

### 10. PR CREATION

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/pr.md`.

### 11. CI WATCH (conditional)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/ci.md`.

### 11b. FINISH WORK (conditional)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/finish.md`.

### 11c. INVESTIGATION DELIVERABLE (conditional)

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/investigation-deliverable.md`.

### Step Mode Routing

This section applies ONLY in step mode. After executing the named step, compute `next_step` using this routing table. In full pipeline mode, this section is ignored — the pipeline proceeds sequentially as before.

**Routing model.** The `next_step` state machine is declared in
`${CLAUDE_PLUGIN_ROOT}/pipeline.json` under `routing[]`. **Read that file** and
evaluate the routing edges for the just-completed `(step, outcome)`:

1. Scan `routing[]` top-to-bottom for rows whose `step` and `outcome` match.
2. For each matching row, evaluate its `when` condition against the current
   config (`$N1_HOME/config.json`) and loop counters (from `overview.md`
   frontmatter). The first row whose `when` is satisfied wins; its `next` is
   `next_step` (`null` terminates the pipeline).
3. `when` grammar (see `plugin/pipeline.schema.md`): `null` = always;
   `"plan"`/`"direct"` = the brainstorm planning need branch (from Planning Need
   Routing below); `{"config": k, "eq"/"neq": v}` = config comparison using the gate
   default when absent; `{"all"|"any": [...]}` = combinators;
   `{"counter": c, "lt"/"gte": k}` = loop-bound check; `{"overview_step": s}` =
   fix-target inference from `overview.md`'s `step:` field.

Gate defaults (`estimation.enabled`=false, `planReview.reviewPlan`=true,
`localTesting.enabled`=false, `ciChecks.enabled`=true, `finishWork.enabled`=false)
and loop bounds (`qa/review/localTesting/ciChecks.maxFixAttempts`, default 3 each)
are the `gates[]`/`loops[]` defaults in `pipeline.json` — do not hardcode them here.

**Investigation mode routing:** When `overview.md` frontmatter has `type: investigation`, the `brainstorm` step routes to `investigation-deliverable` instead of `plan`/`implementation`. The `investigation-deliverable` step is terminal (`next_step: null`). Read the `type` frontmatter before evaluating routing:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
```
If `TYPE` is `investigation`, set `type=investigation` in the routing context passed to `pipeline.json` evaluation (matching the `"when": {"type": "investigation"}` condition in `pipeline.json`).

**Planning need routing (brainstorm routing):** When the `brainstorm` step completes in step mode, the routing logic reads `planning_need` from the brainstorm step result. The autonomous brainstormer evaluates planning need as part of its process (step 8b) and sets the value in its step result. The orchestrator routes `plan` → plan step, `direct` → implementation step. No independent judgment — the brainstormer's evaluation is authoritative.

**Fix step context inference:** The `fix` step determines what to fix by reading `overview.md`'s `step` field. If `step` is `qa`, the fix addresses QA failures (reads `qa.md`). If `step` is `review`, the fix addresses review findings (reads `review.md`). After the fix, `next_step` routes back to the source step for re-verification.

**Step field update before result emission:** In step mode, the `qa` and `review` steps MUST update `overview.md`'s `step:` field to their own name before emitting the structured result. In full pipeline mode this field is written after the fix loop completes, but in step mode the fix loop is external — the `fix` step reads `step:` to determine its target, so the value must be current. Use `n1_write_frontmatter` to update it:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "review"
```

**PR skip routing:** When the `pr` step detects `git.prMode: "skip"` (resolved via the same fallback chain as Step 10), the step completes with `outcome: "pass"` and no CI to monitor — `next_step` is `finish` when `finishWork.enabled` is `true`, otherwise `null`. The `ciChecks.enabled` gate is only consulted when a PR was actually created.

**Config gate resolution in routing:** Gate config keys and their defaults are
declared in `pipeline.json` `gates[]`. Read the gate values from
`$N1_HOME/config.json` via `n1_config_val` (`.estimation.enabled`,
`.planReview.reviewPlan`, `.localTesting.enabled`, `.ciChecks.enabled`,
`.finishWork.enabled`),
applying the `default` from the matching `gates[]` entry when a key is absent.

**Loop counter in result:** When a fix loop increments a counter, include the updated value:

```bash
# After QA fix cycle increment
new_count=$(n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle")
n1_emit_step_result "qa" "fail" "fix" "{\"qa_fix_cycle\":$new_count}"

# After review fix cycle increment
new_count=$(n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
n1_emit_step_result "review" "fail" "fix" "{\"review_fix_cycle\":$new_count}"
```

**Telemetry finalization:** In step mode, do NOT run the full "FINALIZE MEMORY" section (Step 12). That section is for the full pipeline's final wrap-up. In step mode, telemetry is finalized per-step: the step's end marker is emitted as part of normal step execution, and the telemetry lock is NOT removed (subsequent step invocations will overwrite it with their own run ID).

### 12. FINALIZE MEMORY

Update overview.md:
- All checkboxes checked
- Frontmatter: `step: done`
- Add `docs_updated` field from n1-pr's Phase 1 results (if any doc updates occurred; omit entirely when `prMode` was `"skip"` — n1-pr was not invoked)
- Final status line added

**Telemetry finalization (if enabled):**

1. Update the run envelope with completion data:
   ```bash
   echo '{"layer":"envelope_close","run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'","ticket_id":"'"$ID"'","completed_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","final_outcome":"'"$FINAL_OUTCOME"'","estimated_tier":"'"$ESTIMATED_TIER"'"}' >> "${N1_HOME}/memory/$ID/telemetry/raw/steps/$N1_RUN_ID.jsonl"
   ```
   Where `$FINAL_OUTCOME` is one of: `pr_created`, `pr_skipped`, `escalated`, `failed`. `$ESTIMATED_TIER` is the tier from the estimation step (or empty if estimation was skipped).

2. Run the merge script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/telemetry-merge.sh" "$N1_RUN_ID" "${N1_HOME}/memory/$ID/telemetry" 2>&1 || echo "⚠ Telemetry merge failed" >&2
   ```
   After the merge, remove the lock only if the merged output exists and is non-empty:
   ```bash
   MERGED="${N1_HOME}/memory/$ID/telemetry/runs/$N1_RUN_ID.jsonl"
   [ -s "$MERGED" ] && rm -f "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
   ```

## Error Recovery

If any step fails, first classify the failure:

- **Transient** (tracker/MCP timeout, `gh` rate-limit, agent-spawn hiccup, network blip) → retry once or twice with brief backoff before escalating. Most external-call failures are transient.
- **Terminal or ambiguous** (logic error, repeated failure after retry, an unresolvable blocker) → do not retry blindly:
  1. Note the failure in overview.md under `## Escalations`
  2. **Telemetry (if enabled):** Before escalating, emit a final step event with `outcome: "failed"` for the current step, and run the merge script. This ensures interrupted runs produce partial but valid telemetry records.
  3. Report to the user with context
  4. On next `/n1:n1-start <ID>`, resume support picks up from the last successful step

## Context Management

This orchestrator is a **lightweight controller**. It:
- Delegates all heavy work to specialized agent personas (each gets fresh context)
- Loads only the dependency files needed for the current step
- Writes output to memory files after each step (explicit handoff)
- Never accumulates full history in its own context

### Memory hygiene

- **Soft size budget per memory file.** If a file grows large (a long bug investigation in `analysis.md`, a multi-cycle `review.md`), compact it to its high-signal conclusions before the next step reads it — verbose, stale notes are the raw material of context poisoning on long or resumed runs.
- **Re-derive volatile facts on resume.** Treat files-changed lists and test results stored in memory as hints, not ground truth: on resume, re-derive them from `git` and the test suite rather than trusting potentially stale markdown.
