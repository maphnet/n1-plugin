---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--branch] [--investigate]"
model: sonnet
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

- **If N1_HOME could not be resolved** (no matching `~/.n1/<repo-name>/` directory, no `git config n1.home`, and no `.n1/` in project root): Tell the user: "N1 is not configured for this project. Would you like to run `/n1:n1-init` to set it up?" **Wait for response.** If yes — invoke `/n1:n1-init`, then resume. If no — **STOP.**
- **If resolved:** Continue.

## Telemetry Initialization

Read `telemetry.enabled` from `$N1_HOME/config.json` (default `false` if absent or if `telemetry` block is missing).

**If `telemetry.enabled` is `true`:**
1. Read plugin version:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   N1_VERSION=$(n1_config_val '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
   ```
2. Generate run ID:
   ```bash
   N1_RUN_ID=$(date -u +n1-run-%Y%m%dT%H%M%SZ)
   ```
3. Create per-ticket telemetry directories:
   ```bash
   mkdir -p "${N1_HOME}/memory/$ID/telemetry/raw/steps" "${N1_HOME}/memory/$ID/telemetry/raw/agents" "${N1_HOME}/memory/$ID/telemetry/runs"
   ```
4. Write JSON lock file:
   ```bash
   echo '{"run_id":"'"$N1_RUN_ID"'","n1_version":"'"$N1_VERSION"'"}' > "${N1_HOME}/memory/$ID/telemetry/telemetry.lock"
   ```
5. Write active-run pointer (regardless of telemetry setting):
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
   ```
   This file is read by the session-start hook on compaction to restore orchestrator state. It is NOT gated on `telemetry.enabled`.

Where `$ID` is the ticket ID or provisional slug — the same `<ID>` used for the memory directory. The telemetry directory is created at the same moment as the memory directory (using provisional ID if the final ID is not yet known). Since telemetry lives inside `$N1_HOME/memory/<ID>/`, the existing **Reconcile Memory ID & Branch** procedure moves it automatically when the ID changes.

**If `telemetry.enabled` is `false`:** Skip all telemetry shell calls throughout the pipeline. Do not generate `N1_RUN_ID`, do not write lock files, do not emit step markers. The hooks will also exit silently (no lock file = no-op).

Throughout the pipeline, `N1_RUN_ID` and `N1_VERSION` are passed to each telemetry shell call explicitly — do not rely on them persisting between shell calls.

## Input Parsing

The user provides one of:
- **Ticket ID** — matches the tracker prefix from config (e.g., `TRID-510`, `PROJ-42`)
- **Tracker URL** — a URL containing the tracker prefix and ticket number (e.g., `https://maphnet.youtrack.cloud/issue/H1-86/slug-text`)
- **Error tracker URL** — matches `urlPattern` from the error-tracker provider in `observability.providers` (e.g., `https://myorg.sentry.io/issues/12345`)
- **File path** — a path to a file containing requirements
- **Brain dump** — free-text description of what needs to be built
- **Resume** — ticket ID or slug where memory already exists

### Tracker URL normalization:

Before type detection, try to extract a ticket ID from URL inputs. This handles cases where the user pastes a tracker link instead of a bare ticket ID.

Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
EXTRACTED=$(n1_extract_ticket_from_url "<user-input>" "$N1_HOME/config.json") && USER_INPUT="$EXTRACTED" || USER_INPUT="<user-input>"
```

If extraction succeeds, use the extracted ticket ID as input for all subsequent steps. The original URL is discarded — the ticket ID is sufficient for tracker MCP lookups.

### Detect input type:

Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_detect_input_type "$USER_INPUT" "$N1_HOME/config.json"
```

Returns exactly one of: `ticket`, `error-tracker`, `file`, `braindump`.

### Error tracker URL parsing:

When error tracker mode is detected, extract the issue ID from the URL:
- Match the last numeric segment after `/issues/` in the URL path (e.g., `https://myorg.sentry.io/issues/12345` → `12345`)
- If parsing fails (no numeric ID found), fall back to **Brain dump mode** with the URL as text content and warn: "Could not parse issue ID from URL — treating as brain dump."
- Store the original URL for later use in ticket.md and tracker ticket creation.
- The provisional memory ID is `sentry-<issueId>` (e.g., `sentry-12345`). The `sentry-` prefix avoids collision with numeric ticket IDs.

### Branch flag detection

Check if the input contains `--branch`:

```bash
BRANCH_FLAG=false
case "$RAW_INPUT" in
    *--branch*) BRANCH_FLAG=true ;;
esac
```

The `--branch` flag forces branch isolation (no worktree) for this run. Strip `--branch` from the input before passing to ticket/brain-dump parsing.

### Investigate flag detection

Check if the input contains `--investigate`:

```bash
INVESTIGATE_FLAG=false
case "$RAW_INPUT" in
    *--investigate*) INVESTIGATE_FLAG=true ;;
esac
```

The `--investigate` flag starts an interactive investigation. It forces the `investigation` pipeline type (equivalent to `--type investigation`, bypassing title/tag detection) and additionally:

- Forces `BRAINSTORM_MODE=interactive` for this run, overriding `autonomy.brainstorm` from config (the brainstorm step reads `investigate_interactive` from overview.md frontmatter — see steps/brainstorm.md).
- In brain-dump mode, defers tracker ticket creation until the investigation deliverable is complete (see steps/ticket.md and steps/investigation-deliverable.md).

Strip `--investigate` from the input before passing to ticket/brain-dump parsing. Pass `INVESTIGATE_FLAG` in context to the ticket step.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name> [context]
```

The optional `context` parameter enables signal-driven model tiering (e.g., `n1_resolve_model developer fix`). Resolution chain: config override > signal-driven triggers > profile step_overrides > agent frontmatter default.

## Orchestrator Output Discipline

Between steps, emit ONLY: the step name being dispatched, the agent being spawned (with model), and any routing decision with its reason. Do not summarize step outputs, re-describe the task, or narrate intermediate state. Memory files carry context between steps — the orchestrator does not need to.

## Workspace Isolation

### Isolation Mode Resolution

Determine workspace isolation mode using this resolution order:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
WORKTREE_MODE=$(n1_config_val '.worktree.mode')
EXTERNAL_WORKTREE=false
N1_MANAGED_WORKTREE=false

if [ "$WORKTREE_MODE" = "external" ] || n1_is_external_worktree; then
    EXTERNAL_WORKTREE=true
    USE_WORKTREE=false
elif N1_MANAGED_WT_NAME=$(n1_n1_worktree_name); then
    N1_MANAGED_WORKTREE=true
    USE_WORKTREE=false
elif [ "$BRANCH_FLAG" = "true" ]; then
    USE_WORKTREE=false         # --branch flag overrides config
elif [ "$WORKTREE_MODE" = "branch" ]; then
    USE_WORKTREE=false         # config says branch
else
    USE_WORKTREE=true          # default: worktree
fi
```

| Condition | Isolation | Rationale |
|---|---|---|
| `worktree.mode: "external"` or auto-detected external worktree | **External** -- reuse current checkout and branch | Running inside an existing worktree |
| Auto-detected N1-managed worktree (under `.claude/worktrees/`) | **Reuse + rename** -- reuse current worktree, rename to ticket ID if needed | Running inside a pre-existing N1-managed worktree |
| `--branch` flag | **Branch** in current checkout | Explicit user override for this run |
| `worktree.mode: "branch"` | **Branch** in current checkout | User prefers branch isolation |
| Default | **Worktree** | Isolated workspace, no IDE conflicts |

When `EXTERNAL_WORKTREE` is true, skip both Ensure Worktree and Ensure Working Branch — the run operates on the current checkout and its existing branch. Set `WORKTREE_PATH=$(git rev-parse --show-toplevel)` and `BRANCH=$(git branch --show-current)`, then record branch-point: `git merge-base HEAD <defaultBranch>` (fall back to `git rev-parse <defaultBranch>` for shallow clones). Then immediately call:

    source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
    n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"

When `N1_MANAGED_WORKTREE` is true, skip both Ensure Worktree and Ensure Working Branch -- the run operates inside the existing N1-managed worktree. Set `WORKTREE_PATH=$(git rev-parse --show-toplevel)` and `BRANCH=$(git branch --show-current)`, then record branch-point: `git merge-base HEAD <defaultBranch>` (fall back to `git rev-parse <defaultBranch>` for shallow clones). Then immediately call:

    source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
    n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"

The rename to match the ticket ID happens later, after the ID is resolved (see Rename N1-Managed Worktree below).

This explicit write is necessary because the initial active-run write in Telemetry Initialization runs before isolation mode resolution and records null values; ID reconciliation is a no-op when the user provides the ticket ID explicitly, so there is no later write to rely on. When `USE_WORKTREE` is true (and not external), use **Ensure Worktree(`<ID>`)**. When `USE_WORKTREE` is false (and not external), use **Ensure Working Branch(`<ID>`).**

Both procedures are **idempotent** — safe to call again on resume. They are called at each ID-resolution point (see Step 1 and Memory Check).

**PROCEDURE: Ensure Working Branch (`<ID>`)**

1. Compute target branch from `git.branchPattern` (config) + `<ID>`. Patterns: `{prefix}-{id}` → `TRID-510`, `{id}` → `510`, `{slug}`/`feature/{slug}` → `feature/csv-export-users`. Sanitize slug for git ref validity (lowercase, replace spaces/illegal chars with `-`).

2. Read state:
   ```bash
   CURRENT=$(git branch --show-current)
   DEFAULT=<git.defaultBranch from config>
   DIRTY=$(git status --porcelain)
   ```

3. Decide:
   - **`CURRENT` == `TARGET`** → already on it. Reuse silently.
   - **A local branch named `TARGET` already exists AND `DIRTY` is empty** → `git checkout <TARGET>`.
   - **A local branch named `TARGET` already exists AND `DIRTY` is non-empty** → prompt (dirty working tree prompt below).
   - **`CURRENT` == `DEFAULT` AND `DIRTY` is empty** → `git checkout -b <TARGET>`.
   - **`CURRENT` == `DEFAULT` AND `DIRTY` is non-empty** → prompt (dirty working tree prompt below).
   - **`CURRENT` is some OTHER branch AND `DIRTY` is empty** → prompt (foreign branch prompt below).
   - **`CURRENT` is some OTHER branch AND `DIRTY` is non-empty** → prompt (combined prompt below).

**Mechanical-prompt autonomy:** before showing any of the three prompts below, read the policy:

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

If `MP` is `auto`, do NOT prompt — resolve each case with its safe default and append a Decision Ledger row (`skills/n1-start/ledger.md`) to `$N1_HOME/memory/<ID>/overview.md` (write the row after the memory dir exists; if the branch decision happens before memory creation, hold the row and write it together with the first overview.md write):

- **Dirty working tree** → option 1: `git stash push -m "n1: stashed before switching to <TARGET>"`, switch, report "Stashed uncommitted changes. Run `git stash pop` when done."
  Ledger: `| start | mechanical | C | [auto] | Dirty tree before branch switch | Stash and switch | Carry, Abort | mechanicalPrompts=auto; stash is reversible |`
- **Foreign branch** → option 2: switch to `<DEFAULT>`, branch `<TARGET>` from there.
  Ledger: `| start | mechanical | B | [auto] | On '<CURRENT>' not default | Branch from default | Branch from here, Stay | default base avoids accidental stacked branches |`
- **Combined** → option 1: stash, switch to `<DEFAULT>`, branch from there (same stash report).
  Ledger: `| start | mechanical | B | [auto] | Foreign branch + dirty tree | Stash, branch from default | Carry from here, Abort | mechanicalPrompts=auto; both actions reversible |`

The destructive option (Abort) is never auto-selected. If `MP` is `ask` (default) or empty, show the prompts exactly as below.

4. **Dirty working tree prompt** (when on `DEFAULT` or `TARGET` exists, with uncommitted changes):
   ```
   You have uncommitted changes. How should I proceed?
   1 — Stash changes and switch to '<TARGET>' (run `git stash pop` to restore later)
   2 — Carry changes to '<TARGET>' (switch with dirty tree)
   3 — Abort — commit or stash manually first
   ```
   If option 1: run `git stash push -m "n1: stashed before switching to <TARGET>"`, then proceed with the branch switch. Report the stash name so the user can restore it: "Stashed uncommitted changes. Run `git stash pop` when done."

5. **Foreign branch prompt** (when on a branch that is neither `TARGET` nor `DEFAULT`, clean tree):
   ```
   You're on branch '<CURRENT>', not the default ('<DEFAULT>').
   1 — Create '<TARGET>' from here
   2 — Switch to '<DEFAULT>' and branch '<TARGET>' from there
   3 — Keep working on '<CURRENT>'
   ```

6. **Combined prompt** (foreign branch + dirty):
   ```
   You're on branch '<CURRENT>' (not '<DEFAULT>') and have uncommitted changes.
   1 — Stash changes, switch to '<DEFAULT>', branch '<TARGET>' from there (run `git stash pop` to restore later)
   2 — Create '<TARGET>' from '<CURRENT>', carrying uncommitted changes
   3 — Abort — handle manually
   ```
7. **Record review base (creation paths only, idempotent):** on any path that CREATES `<TARGET>` (`git checkout -b`), record the branch point before any commits land:
   ```bash
   mkdir -p "$N1_HOME/memory/<ID>"
   BP_FILE="$N1_HOME/memory/<ID>/branch-point"
   [ -f "$BP_FILE" ] || git rev-parse HEAD > "$BP_FILE"
   ```
   On reuse paths (branch already existed), do NOT write the file.

8. Report: "Working on branch `<TARGET>`."

**PROCEDURE: Ensure Worktree (`<ID>`)**

Used when `USE_WORKTREE` is true (`worktree.mode: "worktree"` in config). Creates or reattaches a worktree at `<main-checkout>/.claude/worktrees/<ID>/`.

1. **Check if `N1_HOME` is absolute** (starts with `/`, `~`, or a drive letter like `C:\`):
   - **If relative** (starts with `.`, e.g. `.n1`) → worktrees cannot be used because config and memory paths would resolve inside the worktree instead of the main checkout. Report to the user: "Worktree isolation requires externalized state (absolute N1_HOME). Run `/n1:n1-init` to migrate, or re-run with `--branch` for branch isolation." **STOP.**
   - **If absolute** → continue with worktree creation.

2. Compute target branch: same formula/sanitization as Ensure Working Branch.

3. Check if a worktree for `<TARGET>` already exists:
   ```bash
   git worktree list --porcelain
   ```

4. **If worktree exists** → store its path as `WORKTREE_PATH`. Report: "Resuming worktree at `<WORKTREE_PATH>`."

5. **If worktree does not exist:**
   a. Compute the main checkout root:
      ```bash
      MAIN_CHECKOUT=$(git rev-parse --show-toplevel)
      WORKTREE_PATH="$MAIN_CHECKOUT/.claude/worktrees/<ID>"
      ```
   b. Create branch (idempotent) and record review base:
      ```bash
      DEFAULT=<git.defaultBranch from config>
      git branch <TARGET> $DEFAULT 2>/dev/null || true
      BP_FILE="$N1_HOME/memory/<ID>/branch-point"
      mkdir -p "$N1_HOME/memory/<ID>"
      [ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$BP_FILE"
      ```
   c. If main checkout is on `<TARGET>` (blocks `git worktree add`):
      ```bash
      CURRENT=$(git branch --show-current)
      ```
      If `CURRENT == TARGET`: `git checkout $DEFAULT`.
   d. Create the worktree:
      ```bash
      git worktree add "$WORKTREE_PATH" <TARGET>
      ```
      If this fails because the directory already exists (e.g., from a crashed prior run), manually remove `<main-checkout>/.claude/worktrees/<ID>/` or run `/n1:n1-clean` to clean up stale worktrees, then retry.
   e. Report: "Working in worktree `$WORKTREE_PATH` on branch `<TARGET>`."
   f. **IDE hint.** Print an additional line:
      > Open this directory in your IDE: `$WORKTREE_PATH`

**PROCEDURE: Ensure Dependencies (`<ID>`)**

Idempotent, marker-guarded. Called by implementation and defensively by qa/review/local-testing when `USE_WORKTREE` is true.

1. **Worktree check.** If `USE_WORKTREE` is false → return.
2. **Config check.** Read `worktree.setup` from config:
   ```bash
   SETUP=$(n1_config_val '.worktree.setup')
   ```
   If `SETUP` is empty, `null`, or absent → return (nothing to install).
3. **Marker check.** Resolve `WORKTREE_PATH` (from `git worktree list`, same parse as Ensure Worktree). If `<WORKTREE_PATH>/.n1-deps-installed` exists → return.
4. **Install.**
   ```bash
   cd "$WORKTREE_PATH" && eval "$SETUP"
   ```
   - **On success:** `touch "$WORKTREE_PATH/.n1-deps-installed"`; report
     "Dependencies installed via `$SETUP`."
   - **On failure:** do NOT create the marker (so the next run / a Retry re-attempts). Do NOT diagnose or repair the environment inline (no `which python`, no `pip install` of individual packages, no venv inspection) — capture stderr and follow the retry/prompt path below exactly; deeper environment work belongs to the developer spawn of the current step.
     Read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP` is `auto` AND this is the first attempt (no prior retry recorded in overview.md `## Escalations`): append `worktree setup auto-retry attempted` to overview.md `## Escalations`, then re-run step 4 once. If the retry succeeds, continue normally. If the retry also fails (or `MP` is not `auto`): report the command's stderr and ask the user:
     ```
     Worktree dependency setup failed. How should I proceed?
     1 — Retry setup (a transient install failure usually clears on retry)
     2 — Skip and continue anyway
     3 — Abort — stop the pipeline
     ```
     - "Retry setup" → re-run step 4.
     - "Skip and continue anyway" → record in overview `## Escalations`
       ("worktree setup skipped by user"), do NOT create the marker, and continue the step.
     - "Abort" → record it in overview `## Escalations` and STOP.

**PROCEDURE: Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)**

**Idempotent.** Renames memory dir, branch, and worktree when the final `<ID>` differs from the provisional slug. `<oldId>` = provisional slug; `<newId>` = final ID.

1. **If `<oldId>` == `<newId>`** → return (no-op).
2. **Memory move:** if `$N1_HOME/memory/<oldId>/` exists AND `$N1_HOME/memory/<newId>/` does NOT → filesystem-move the directory `<oldId>/` → `<newId>/` (`$N1_HOME/` is gitignored or outside the repo, so a plain `mv` / `Move-Item`, NOT `git mv`). If `$N1_HOME/memory/<newId>/` already exists, skip the move and report — the `<newId>` memory is authoritative (resume/collision guard).
3. **Frontmatter fix:** if `$N1_HOME/memory/<newId>/overview.md` exists (true only when an overview was already written under the slug and just moved — in the clean path it does not exist yet), rewrite its `ticket: <oldId>` → `ticket: <newId>` and its `# <oldId>: <Title>` heading → `# <newId>: <Title>`.
4. **Branch rename:** compute `<oldBranch>` and `<newBranch>` from `git.branchPattern` (config). If a local branch `<oldBranch>` exists AND `<newBranch>` does NOT → `git branch -m <oldBranch> <newBranch>` (rename preserves commits; N1 has not pushed yet). If `<newBranch>` already exists, skip the rename.
5. **Worktree move:** if `EXTERNAL_WORKTREE` is true → skip (external worktrees are not relocated). Otherwise, if `.claude/worktrees/<oldId>/` exists → compute `MAIN_CHECKOUT=$(git rev-parse --show-toplevel)` and run `git worktree move $MAIN_CHECKOUT/.claude/worktrees/<oldId> $MAIN_CHECKOUT/.claude/worktrees/<newId>`. In branch mode, no worktree exists — skip silently.
6. Report: "Migrated memory + branch `<oldId>` → `<newId>`." (append "+ worktree" if a worktree was moved)
7. **Update active-run pointer:**
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
   ```

**PROCEDURE: Rename N1-Managed Worktree (`<ID>`)**

Called when `N1_MANAGED_WORKTREE` is true, after the ticket ID is resolved. Renames the current worktree directory to match the ticket ID using `git worktree move`.

1. **If `N1_MANAGED_WT_NAME` == `<ID>`** -- return (worktree name already matches).

2. **Collision check.** Compute target path:
   ```bash
   MAIN_CHECKOUT=$(dirname "$(cd "$WORKTREE_PATH" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" && pwd -P)")
   TARGET_PATH="$MAIN_CHECKOUT/.claude/worktrees/<ID>"
   ```
   If `TARGET_PATH` already exists -- report warning: "Cannot rename worktree: `<TARGET_PATH>` already exists. Continuing with current path." Return without error.

3. **Rename:**
   ```bash
   git worktree move "$WORKTREE_PATH" "$TARGET_PATH"
   ```
   If `git worktree move` fails -- report warning with stderr. Return without error (the pipeline continues with the old path).

4. **Update state and CWD:**
   ```bash
   WORKTREE_PATH="$TARGET_PATH"
   cd "$WORKTREE_PATH"
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"
   ```
   The `cd` is critical: the orchestrator's CWD pointed to the old (now-deleted) path. Without it, all subsequent Bash commands fail with "no such file or directory."

5. Report: "Renamed worktree `<N1_MANAGED_WT_NAME>` to `<ID>` at `$WORKTREE_PATH`."

6. **IDE hint.** Print:
   > Open this directory in your IDE: `$WORKTREE_PATH`

### Agent Working Directory

When `USE_WORKTREE` is true and `WORKTREE_PATH` is set, pass this directive to every agent spawn that reads or modifies source code (qa-engineer, code-reviewer, security-reviewer, developer in fix cycles, tech-writer, solution-architect for local testing):

> Work in the worktree directory at `WORKTREE_PATH`. All file read/write/edit/grep/glob operations and all git/bash commands that touch the codebase MUST target files within this directory, not the main checkout. Memory files remain at `$N1_HOME/memory/<ID>/` (unchanged).

In branch mode (`USE_WORKTREE` is false), omit this directive — agents work in the current directory on the feature branch.

### Post-Compaction Recovery

When Claude Code compacts the conversation context, the session-start hook fires synchronously and injects an **ORCHESTRATOR STATE** block into `additionalContext`. This block contains the authoritative runtime state: N1_HOME, active ticket, current step, worktree path, branch, loop counters, autonomy settings, and config gates.

**After any compaction, you MUST:**

1. Read the ORCHESTRATOR STATE block from the re-injected session context — it is marked "authoritative, overrides any compacted summary"
2. Use those values for all subsequent decisions — tracker type, MCP prefix, worktree path, step routing, loop counters
3. Do NOT rely on the compacted conversation summary for config or routing values — compaction is lossy and may distort tracker type, MCP names, or other critical state
4. If the ORCHESTRATOR STATE block is missing (no active run), re-resolve N1_HOME and re-read config.json via Bash before continuing:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   N1_HOME=$(n1_home)
   cat "$N1_HOME/config.json"
   ```

This is belt-and-suspenders: the hook guarantees config delivery, the directive ensures the orchestrator knows to trust it over the compacted summary.

## Memory Check (Resume Support)

Check if `$N1_HOME/memory/<input>/overview.md` exists:

- **If exists:** Read the overview frontmatter to determine current step. Also read the pipeline type:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
  ```
  When `TYPE` is `"investigation"`, the pipeline runs the shortened investigation flow (see Step 3b and Planning Need Routing below) — skip workspace isolation (no branch or worktree needed for investigation tasks). When `EXTERNAL_WORKTREE` is true, skip workspace isolation entirely — the external checkout is reused (set `WORKTREE_PATH` and `BRANCH` from git as described in Isolation Mode Resolution above). Otherwise, run the appropriate workspace isolation procedure: if `N1_MANAGED_WORKTREE` is true, run **Rename N1-Managed Worktree(`<ID>`)**; otherwise, run **Ensure Worktree(`<ID>`)** when `USE_WORKTREE` is true, or **Ensure Working Branch(`<ID>`)** when `USE_WORKTREE` is false (see Workspace Isolation above). This covers resuming from a session that ended without cleanup. Then resume from where work left off: read the dependency files for the current step (see dependency map below) and continue. **Also read the loop counters** (`qa_fix_cycle`, `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, and `ci_fix_cycle` if present) so bounded loops resume at their true count, not zero (see Loop-Counter Durability below). Read each via:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
  ```
- **If not exists:** Fresh start. Create `$N1_HOME/memory/<ID>/` directory.

### Step dependency map

Read `pipeline.json` under `steps[]` for dependency declarations.

### Loop-counter durability & crash-safe checkpointing

- **Loop counters live in overview frontmatter**, never only in orchestrator context: `qa_fix_cycle`, `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle` (and `ci_fix_cycle`, owned by n1-ci). Increment them in the file as each loop turns and read them back on resume. A bound held only in context resets to zero on restart, silently defeating it.
- **Overview is the single source of truth for progress.** Each step writes its output file FIRST, then updates `step:`/checkbox in overview LAST. On resume, a step counts as done only if overview says so. If a crash lands between the two writes (output file exists but overview still points at the prior step), re-running is safe because every artifact write is a full overwrite — idempotent, never an append.

**Dependency integrity guard (applies to every step).** Before spawning a step's agent or sub-skill, run:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```

(Pass the declared dependency files for the current step — see table above.) If any dependency is missing or empty, the function prints the missing files to stderr and returns non-zero — **STOP and report** rather than proceeding with a degraded handoff. (`ticket.md` with no acceptance criteria is handled upstream by product-analyst and is not a hard stop.)

## Autonomy Gate (qualityEscalations)

When a quality step has findings that the user would normally be prompted about, check the autonomy policy first.

**Parameters:** `{step}`, `{action}` (what auto-accept does, e.g. "accept remaining findings"), `{ledger_context}` (summary for the Decision Ledger row)

```bash
QE=$(n1_autonomy_val 'qualityEscalations')
```

**If `QE` is `auto-accept`** AND the findings do NOT involve security, architecture, or public API changes: take `{action}` silently. Append a Decision Ledger row to overview.md:

`| {step} | quality | A | [auto] | {ledger_context} | {action} | Prompt user | qualityEscalations=auto-accept |`

**If `QE` is `block`** (default) or the findings involve security/architecture/public API: show the interactive prompt as defined by the step file.

## Rules Injection

Prepare a rules block to inject into an agent spawn prompt. The block is empty when no matching rules exist.

**Parameters:** `{agent_name}` (e.g. `"developer"`, `"solution-architect"`), `{changed_files_source}` (optional signal key to read changed files from, e.g. `"diff_surface"` from `implementation.md`)

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    CHANGED_FILES=""
    # If changed_files_source is provided, read the signal
    # CHANGED_FILES=$(n1_read_signal "$N1_HOME/memory/$ID/{source_file}" "{changed_files_source}")
    MATCHING_RULES=$(n1_rules_for_agent "{agent_name}" "$CHANGED_FILES" "$RULES_DIR")
    if [ -n "$MATCHING_RULES" ]; then
        RULES_BLOCK=$(n1_rules_render $MATCHING_RULES)
    fi
fi
```

When `$RULES_BLOCK` is non-empty, append it to the agent's spawn prompt.

## Pipeline Steps

Step 3 (Brainstorm) is **INTERACTIVE** by default — Superpowers handles user interaction during brainstorming. When `autonomy.brainstorm` is `auto`, the autonomous brainstormer runs headlessly instead, asking the user only for blocking questions. Step 4 (Plan checkpoint) pauses for explicit plan approval when `requirePlanApproval` is enabled.

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

**Naming note:** The overview.md frontmatter `tier:` field (values: `simple`/`standard`/`complex`) controls model/effort routing. The brainstorm `planning_need` value (values: `plan`/`direct`) controls pipeline branching — whether a formal plan is needed. The estimation body line `**Complexity:** XS/S/M/L/XL` is delivery sizing. These three concepts are independent.

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

**Investigation mode:** If `TYPE` is `"investigation"` (read from overview.md frontmatter via `n1_read_type`), skip planning need routing entirely — investigation tasks always proceed from brainstorm to the investigation-deliverable step.

Read `planning_need` from the brainstorm step output (set by the brainstormer in Step 3). Route:
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

**Execute step:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/review.md`. That step references `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/review-core.md` for shared diff-surface classification, Codex gating, and reviewer scope rules.

Autonomous decisions made anywhere in the pipeline are recorded per `skills/n1-start/ledger.md` (Decision Ledger in overview.md, rendered into the PR body).

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

After finalizing, clear the active-run pointer:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_active_run_clear
```

## Error Recovery

If any step fails, first classify the failure:

- **Transient** (tracker/MCP timeout, `gh` rate-limit, agent-spawn hiccup, network blip) → retry once or twice with brief backoff before escalating.
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
