# Procedure: Workspace Isolation

## Isolation Mode Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
WORKTREE_MODE=$(n1_config_val '.worktree.mode'); EXTERNAL_WORKTREE=false
if [ "$WORKTREE_MODE" = "external" ] || n1_is_external_worktree; then EXTERNAL_WORKTREE=true; USE_WORKTREE=false
elif [ "$BRANCH_FLAG" = "true" ] || [ "$WORKTREE_MODE" = "branch" ]; then USE_WORKTREE=false
else USE_WORKTREE=true; fi
```

| Condition | Isolation |
|---|---|
| `worktree.mode: external` or auto-detected | External — reuse checkout |
| `--branch` or `worktree.mode: branch` | Branch in current checkout |
| Default | Worktree |

`EXTERNAL_WORKTREE=true`: skip Ensure Worktree/Branch; set `WORKTREE_PATH`, `BRANCH`, record branch-point; `n1_active_run_write`. Idempotent.

## Ensure Working Branch (`<ID>`)

1. Target=`git.branchPattern`+`<ID>` (lowercase, illegal→`-`). 2. Read `CURRENT`, `DEFAULT`, `DIRTY`. 3. `CURRENT==TARGET`→reuse; target exists+clean→checkout; `CURRENT==DEFAULT`+clean→`git checkout -b <TARGET>`; dirty/foreign: `MP=auto`→stash/switch+ledger; `MP=ask`→`procedures/workspace-isolation-recovery.md`. 4. Record branch-point if absent. 5. Report.

## Ensure Worktree (`<ID>`)

1. `N1_HOME` must be absolute; relative→error+STOP. 2. Compute target. Check `git worktree list --porcelain`: exists→resume. 3. Not exists:
```bash
MAIN_CHECKOUT=$(git rev-parse --show-toplevel); WT_ROOT=$(n1_worktree_root)
WORKTREE_PATH="$MAIN_CHECKOUT/$WT_ROOT/<ID>"; DEFAULT=<git.defaultBranch>
git branch <TARGET> $DEFAULT 2>/dev/null || true
[ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$N1_HOME/memory/<ID>/branch-point"
CURRENT=$(git branch --show-current); [ "$CURRENT" = "$TARGET" ] && git checkout $DEFAULT
git worktree add "$WORKTREE_PATH" <TARGET>
```
`git worktree add` fail→recovery.

## Ensure Dependencies (`<ID>`)

Idempotent, marker-guarded. `USE_WORKTREE=false`→return. `SETUP=$(n1_config_val '.worktree.setup')`; empty→return. `.n1-deps-installed` exists→return. `cd "$WORKTREE_PATH" && eval "$SETUP"`; success→`touch ".n1-deps-installed"`; fail→recovery. Do NOT diagnose or repair the environment inline — use recovery procedure.

## Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)

`oldId==newId`→return. Move memory dir, rewrite `ticket:` frontmatter, `git branch -m`, `git worktree move`. Update active-run:
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/config.sh"
n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

## Agent Working Directory

`USE_WORKTREE=true`+`WORKTREE_PATH` set: pass to every source agent: "Work in `$WORKTREE_PATH`. All file ops and git/bash MUST target files within. Memory: `$N1_HOME/memory/<ID>/`." Unexpected→recovery.
