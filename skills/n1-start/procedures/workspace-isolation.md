# Procedure: Workspace Isolation

Covers isolation mode resolution, branch/worktree creation, dependency installation, and memory/branch reconciliation.

## Isolation Mode Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"
source "$N1_ROOT/lib/config.sh"
WORKTREE_MODE=$(n1_config_val '.worktree.mode')
EXTERNAL_WORKTREE=false

if [ "$WORKTREE_MODE" = "external" ] || n1_is_external_worktree; then
    EXTERNAL_WORKTREE=true
    USE_WORKTREE=false
elif [ "$BRANCH_FLAG" = "true" ]; then
    USE_WORKTREE=false
elif [ "$WORKTREE_MODE" = "branch" ]; then
    USE_WORKTREE=false
else
    USE_WORKTREE=true
fi
```

| Condition | Isolation |
|---|---|
| `worktree.mode: "external"` or auto-detected external worktree | External — reuse current checkout |
| `--branch` flag | Branch in current checkout |
| `worktree.mode: "branch"` | Branch in current checkout |
| Default | Worktree |

When `EXTERNAL_WORKTREE=true`: skip Ensure Worktree/Branch. Set `WORKTREE_PATH=$(git rev-parse --show-toplevel)`, `BRANCH=$(git branch --show-current)`, record branch-point. Then:
```
source "<N1_ROOT>/lib/config.sh"
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"
```
Both procedures are **idempotent** — safe to call on resume.

## PROCEDURE: Ensure Working Branch (`<ID>`)

1. Compute target branch from `git.branchPattern` + `<ID>`. Sanitize slug (lowercase, illegal chars → `-`).
2. Read state: `CURRENT=$(git branch --show-current)`, `DEFAULT=<git.defaultBranch>`, `DIRTY=$(git status --porcelain)`.
3. Decide:
   - `CURRENT==TARGET` → reuse silently.
   - Target exists AND `DIRTY` empty → `git checkout <TARGET>`.
   - `CURRENT==DEFAULT` AND `DIRTY` empty → `git checkout -b <TARGET>`.
   - Any dirty tree or foreign branch case → read `MP=$(n1_autonomy_val 'mechanicalPrompts')`.

**Mechanical-prompt autonomy** (`MP=auto`): resolve without prompting; append Decision Ledger row:
- Dirty tree → stash + switch: `git stash push -m "n1: stashed before switching to <TARGET>"`.
- Foreign branch → switch to DEFAULT, branch TARGET from there.
- Combined → stash + switch to DEFAULT + branch TARGET.

If `MP=ask` (default): present prompts (see `procedures/workspace-isolation-recovery.md` for prompt text and option details).

4. **Record review base** (on creation paths only): `[ -f "$BP_FILE" ] || git rev-parse HEAD > "$N1_HOME/memory/<ID>/branch-point"`.
5. Report: "Working on branch `<TARGET>`."

## PROCEDURE: Ensure Worktree (`<ID>`)

Used when `USE_WORKTREE=true`.

1. Check `N1_HOME` is absolute. If relative: "Worktree isolation requires externalized state (absolute N1_HOME). Run `/n1:n1-init` to migrate, or re-run with `--branch`." **STOP.**
2. Compute target branch (same as Ensure Working Branch).
3. Check existing worktrees: `git worktree list --porcelain`.
4. If exists → `WORKTREE_PATH=<existing path>`. Report: "Resuming worktree at `<WORKTREE_PATH>`."
5. If not exists:
   ```bash
   MAIN_CHECKOUT=$(git rev-parse --show-toplevel)
   WT_ROOT=$(n1_worktree_root)
   WORKTREE_PATH="$MAIN_CHECKOUT/$WT_ROOT/<ID>"
   DEFAULT=<git.defaultBranch>
   git branch <TARGET> $DEFAULT 2>/dev/null || true
   [ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$N1_HOME/memory/<ID>/branch-point"
   CURRENT=$(git branch --show-current)
   [ "$CURRENT" = "$TARGET" ] && git checkout $DEFAULT
   git worktree add "$WORKTREE_PATH" <TARGET>
   ```
   If `git worktree add` fails (directory already exists from a crashed run): see `procedures/workspace-isolation-recovery.md`.

## PROCEDURE: Ensure Dependencies (`<ID>`)

Idempotent, marker-guarded. Called by implementation and defensively by qa/review/local-testing when `USE_WORKTREE=true`.

1. If `USE_WORKTREE=false` → return.
2. Read `SETUP=$(n1_config_val '.worktree.setup')`. If empty/null/absent → return.
3. If `<WORKTREE_PATH>/.n1-deps-installed` exists → return.
4. `cd "$WORKTREE_PATH" && eval "$SETUP"`. On success: `touch "$WORKTREE_PATH/.n1-deps-installed"`. On failure: see `procedures/workspace-isolation-recovery.md`.

## PROCEDURE: Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)

**Idempotent.** Renames memory dir, branch, and worktree when final `<ID>` differs from provisional slug.

1. If `<oldId>==<newId>` → return.
2. Memory move: if `$N1_HOME/memory/<oldId>/` exists AND `$N1_HOME/memory/<newId>/` does NOT → `mv <oldId>/ <newId>/`. If newId exists: skip (newId is authoritative).
3. Frontmatter fix: if overview.md exists after move, rewrite `ticket: <oldId>` → `ticket: <newId>` and `# <oldId>:` heading.
4. Branch rename: if `<oldBranch>` exists AND `<newBranch>` does NOT → `git branch -m <oldBranch> <newBranch>`.
5. Worktree move: if `EXTERNAL_WORKTREE=true` → skip. Else if `<worktree-root>/<oldId>/` exists: `git worktree move $MAIN_CHECKOUT/$WT_ROOT/<oldId> $MAIN_CHECKOUT/$WT_ROOT/<newId>`.
6. Report: "Migrated memory + branch `<oldId>` → `<newId>`." (append "+ worktree" if moved)
7. Update active-run pointer:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/step.sh"
   source "$N1_ROOT/lib/config.sh"
   n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
   ```

## Agent Working Directory

When `USE_WORKTREE=true` and `WORKTREE_PATH` set, pass to every agent spawn that reads/modifies source code:

> Work in the worktree at `WORKTREE_PATH`. All file operations and git/bash commands that touch the codebase MUST target files within this directory. Memory files remain at `$N1_HOME/memory/<ID>/`.

In branch mode, omit this directive.

If workspace creation fails or you encounter an unexpected condition, read `procedures/workspace-isolation-recovery.md`.
