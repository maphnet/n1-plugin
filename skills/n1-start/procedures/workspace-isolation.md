# Procedure: Workspace Isolation

## Isolation Mode Resolution

```bash
source ~/.n1/preamble.sh
if n1_is_external_worktree; then EXTERNAL_WORKTREE=true; USE_WORKTREE=false; else EXTERNAL_WORKTREE=false; USE_WORKTREE=true; fi
```

| Condition | Isolation |
|---|---|
| External linked worktree (auto-detected) | Reuse checkout |
| Default | Worktree |

`EXTERNAL_WORKTREE=true`: skip Ensure Worktree; set `WORKTREE_PATH`, `BRANCH`, record branch-point; `n1_active_run_write`. Idempotent.

## Ensure Worktree (`<ID>`)

1. `N1_HOME` must be absolute; relative→error+STOP. 2. Compute target. Check `git worktree list --porcelain`: exists→resume. 3. Not exists:
```bash
source ~/.n1/preamble.sh
MAIN_CHECKOUT=$(git rev-parse --show-toplevel); WT_ROOT=$(n1_worktree_root)
WORKTREE_PATH="$MAIN_CHECKOUT/$WT_ROOT/<ID>"; DEFAULT=<git.defaultBranch>
git branch <TARGET> $DEFAULT 2>/dev/null || true
[ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$N1_HOME/memory/<ID>/branch-point"
CURRENT=$(git branch --show-current); [ "$CURRENT" = "$TARGET" ] && git checkout $DEFAULT
git worktree add "$WORKTREE_PATH" <TARGET> && n1_copy_worktree_files "$MAIN_CHECKOUT" "$WORKTREE_PATH"
```
`git worktree add` fail→recovery.

## Ensure Dependencies (`<ID>`)

Idempotent, marker-guarded. `USE_WORKTREE=false`→return. `SETUP=$(n1_config_val '.worktree.setup')`; empty→return. `.n1-deps-installed` exists→return. `cd "$WORKTREE_PATH" && eval "$SETUP"`; success→`touch ".n1-deps-installed"`; fail→recovery. Do NOT diagnose or repair the environment inline — use recovery procedure.

## Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)

`oldId==newId`→return. Move memory dir, rewrite `ticket:` frontmatter, `git branch -m`, `git worktree move`. Update active-run:
```bash
source ~/.n1/preamble.sh
n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

## Agent Working Directory

`USE_WORKTREE=true`+`WORKTREE_PATH` set: pass to every source agent: "Work in `$WORKTREE_PATH`. All file ops and git/bash MUST target files within. Memory: `$N1_HOME/memory/<ID>/`." Unexpected→recovery.
