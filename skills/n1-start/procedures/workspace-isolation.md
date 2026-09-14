# Procedure: Workspace Isolation

Covers isolation mode resolution, branch/worktree creation, dependency installation, and memory/branch reconciliation.

## Workspace Isolation

### Isolation Mode Resolution

Determine workspace isolation mode using this resolution order:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
WORKTREE_MODE=$(n1_config_val '.worktree.mode')
EXTERNAL_WORKTREE=false

if [ "$WORKTREE_MODE" = "external" ] || n1_is_external_worktree; then
    EXTERNAL_WORKTREE=true
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
| `worktree.mode: "external"` or auto-detected external worktree | **External** — reuse current checkout and branch | Running inside an existing worktree |
| `--branch` flag | **Branch** in current checkout | Explicit user override for this run |
| `worktree.mode: "branch"` | **Branch** in current checkout | User prefers branch isolation |
| Default | **Worktree** | Isolated workspace, no IDE conflicts |

When `EXTERNAL_WORKTREE` is true, skip both Ensure Worktree and Ensure Working Branch — the run operates on the current checkout and its existing branch. Set `WORKTREE_PATH=$(git rev-parse --show-toplevel)` and `BRANCH=$(git branch --show-current)`, then record branch-point: `git merge-base HEAD <defaultBranch>` (fall back to `git rev-parse <defaultBranch>` for shallow clones). Then immediately call:

    source "<N1_ROOT>/lib/config.sh"
    n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"

This explicit write is necessary because the initial active-run write in Telemetry Initialization runs before isolation mode resolution and records null values; ID reconciliation is a no-op when the user provides the ticket ID explicitly, so there is no later write to rely on. When `USE_WORKTREE` is true (and not external), use **Ensure Worktree(`<ID>`)**.  When `USE_WORKTREE` is false (and not external), use **Ensure Working Branch(`<ID>`).**

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

Before any user prompt on this path, write the pending marker so compaction recovery knows a prompt is in flight:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/frontmatter.sh"
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" "<one-line description of the question>"
```
After the answer is received, clear it: `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" ""`.

**Mechanical-prompt autonomy:** before showing any of the three prompts below, read the policy:

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

If `MP` is `auto`, do NOT prompt — resolve each case with its safe default and append a Decision Ledger row (`skills/n1-start/ledger.md`) to `$N1_HOME/memory/<ID>/overview.md` (write the row after the memory dir exists; if the branch decision happens before memory creation, hold the row and write it together with the first overview.md write):

- **Dirty working tree** → option 1: `git stash push -m "n1: stashed before switching to <TARGET>"`, switch, report "Stashed uncommitted changes. Run `git stash pop` when done."
  Ledger: `| start | mechanical | C | [auto] | Dirty tree before branch switch | Stash and switch | Carry, Abort | mechanicalPrompts=auto; stash is reversible | --- |`
- **Foreign branch** → option 2: switch to `<DEFAULT>`, branch `<TARGET>` from there.
  Ledger: `| start | mechanical | B | [auto] | On '<CURRENT>' not default | Branch from default | Branch from here, Stay | default base avoids accidental stacked branches | --- |`
- **Combined** → option 1: stash, switch to `<DEFAULT>`, branch from there (same stash report).
  Ledger: `| start | mechanical | B | [auto] | Foreign branch + dirty tree | Stash, branch from default | Carry from here, Abort | mechanicalPrompts=auto; both actions reversible | --- |`

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

Used when `USE_WORKTREE` is true (`worktree.mode: "worktree"` in config). Creates or reattaches a worktree at `<main-checkout>/<worktree-root>/<ID>/` where `<worktree-root>` is `n1_worktree_root` (config `worktree.root`, else the host default from HOST ROUTING).

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
      WT_ROOT=$(n1_worktree_root)
      WORKTREE_PATH="$MAIN_CHECKOUT/$WT_ROOT/<ID>"
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
      If this fails because the directory already exists (e.g., from a crashed prior run), manually remove `<main-checkout>/<worktree-root>/<ID>/` or run `/n1:n1-clean` to clean up stale worktrees, then retry.
   e. Set `WORKTREE_PATH` and `BRANCH` for use in Gate 1's `Workspace:` line. Do not print a report here — Gate 1 surfaces these values after analysis.

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
   - **On success:** `touch "$WORKTREE_PATH/.n1-deps-installed"`. Do not print a report — success is not news.
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
5. **Worktree move:** if `EXTERNAL_WORKTREE` is true → skip (external worktrees are not relocated). Otherwise, if `<worktree-root>/<oldId>/` exists → compute `MAIN_CHECKOUT=$(git rev-parse --show-toplevel); WT_ROOT=$(n1_worktree_root)` and run `git worktree move $MAIN_CHECKOUT/$WT_ROOT/<oldId> $MAIN_CHECKOUT/$WT_ROOT/<newId>`. In branch mode, no worktree exists — skip silently.
6. Report: "Migrated memory + branch `<oldId>` → `<newId>`." (append "+ worktree" if a worktree was moved)
7. **Update active-run pointer:**
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/config.sh"
   n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
   ```

### Agent Working Directory

When `USE_WORKTREE` is true and `WORKTREE_PATH` is set, pass this directive to every agent spawn that reads or modifies source code (qa-engineer, code-reviewer, security-reviewer, developer in fix cycles, tech-writer, solution-architect for local testing):

> Work in the worktree directory at `WORKTREE_PATH`. All file read/write/edit/grep/glob operations and all git/bash commands that touch the codebase MUST target files within this directory, not the main checkout. Memory files remain at `$N1_HOME/memory/<ID>/` (unchanged).

In branch mode (`USE_WORKTREE` is false), omit this directive — agents work in the current directory on the feature branch.
