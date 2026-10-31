# Procedure: Workspace Isolation

## Workspace Decision (`<ID>`)

Runs at the end of `steps/ticket.md` (`FRESH=1`) and from `procedures/resume.md` (`FRESH=0`); never for investigation. Add `--no-handoff` when `NO_HANDOFF=true`.
```bash
source ~/.n1/preamble.sh
n1_workspace_decide "<ID>" <--no-handoff, or nothing>
```

| Token | Action |
|---|---|
| `stay <path>` | `USE_WORKTREE=false` when `n1_is_external_worktree` succeeds (as today), else `true` (N1-managed: keeps Ensure Dependencies); **Adopt Checkout** `<path>` |
| `ask <path> <branch>` | `procedures/workspace-ownership.md § Ask` |
| `reuse <path>` | `USE_WORKTREE=true`; **Adopt Checkout** `<path>` |
| `handoff-create`, `handoff-launch <path>` | `procedures/workspace-ownership.md § Handoff` |
| `create-local` | `USE_WORKTREE=true`; **Ensure Worktree** |

**Adopt Checkout** (`<path>`; idempotent):
```bash
source ~/.n1/preamble.sh
ID="<ID>"; WORKTREE_PATH="<path>"; FRESH=<1|0>; OV="$N1_HOME/memory/$ID/overview.md"; BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current)
n1_write_frontmatter "$OV" workspace_path "$WORKTREE_PATH"
BP="$N1_HOME/memory/$ID/branch-point"; DEFAULT=$(n1_config_val '.git.defaultBranch'); DEFAULT="${DEFAULT:-main}"
[ -s "$BP" ] || { git -C "$WORKTREE_PATH" merge-base HEAD "origin/$DEFAULT" 2>/dev/null || git -C "$WORKTREE_PATH" merge-base HEAD "$DEFAULT"; } > "$BP" || rm -f "$BP"
if [ "$FRESH" = 1 ] || [ "$(n1_read_frontmatter "$OV" step)" = ticket ]; then (cd "$WORKTREE_PATH" && n1_orca_sync "ticket: in progress" --status in-progress && { [ "$(n1_config_val '.tracker.type')" != jira ] || n1_orca_link "$ID"; }); fi
n1_active_run_write "$ID" "${N1_RUN_ID:-none}" "$WORKTREE_PATH" "$BRANCH"
echo "WORKTREE_PATH=$WORKTREE_PATH BRANCH=$BRANCH"
```

## Ensure Worktree (`<ID>`)

1. `N1_HOME` must be absolute; relative→error+STOP. 2. Compute target. Check `git worktree list --porcelain`: exists→resume. 3. Not exists:
```bash
source ~/.n1/preamble.sh
MAIN_CHECKOUT=$(git worktree list --porcelain | sed -n '1s/^worktree //p'); WT_ROOT=$(n1_worktree_root)
WORKTREE_PATH="$MAIN_CHECKOUT/$WT_ROOT/<ID>"; DEFAULT=<git.defaultBranch>
git branch <TARGET> $DEFAULT 2>/dev/null || true
[ -f "$BP_FILE" ] || git rev-parse "$DEFAULT" > "$N1_HOME/memory/<ID>/branch-point"
CURRENT=$(git branch --show-current); [ "$CURRENT" = "$TARGET" ] && git checkout $DEFAULT
git worktree add "$WORKTREE_PATH" <TARGET> && n1_copy_worktree_files "$MAIN_CHECKOUT" "$WORKTREE_PATH" && n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" workspace_path "$WORKTREE_PATH"
```
`git worktree add` fail→recovery.

## Ensure Dependencies (`<ID>`)

Idempotent, marker-guarded. `USE_WORKTREE=false`→return. `SETUP=$(n1_config_val '.worktree.setup')`; empty→return. `.n1-deps-installed` exists→return. `cd "$WORKTREE_PATH" && eval "$SETUP"`; success→`touch ".n1-deps-installed"`; fail→recovery. Do NOT diagnose or repair the environment inline — use recovery procedure.

## Reconcile Memory ID & Branch (`<oldId>`, `<newId>`)

`oldId==newId`→return. Move memory dir, rewrite `ticket:` frontmatter; `git branch -m`, `git worktree move` only when they exist. Update active-run:
```bash
source ~/.n1/preamble.sh
n1_active_run_write "$newId" "${N1_RUN_ID:-none}" "${WORKTREE_PATH:-null}" "${BRANCH:-}"
```

## Agent Working Directory

`USE_WORKTREE=true`+`WORKTREE_PATH` set: pass to every source agent: "Work in `$WORKTREE_PATH`. All file ops and git/bash MUST target files within. Memory: `$N1_HOME/memory/<ID>/`." Unexpected→recovery.
