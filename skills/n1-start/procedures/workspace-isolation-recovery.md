# Procedure: Workspace Isolation — Recovery

Read this file only when `procedures/workspace-isolation.md` instructs you to (workspace creation fails or unexpected condition encountered).

## Pending Prompt Marker

Before any user prompt, write pending marker:
```bash
source ~/.n1/preamble.sh
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" "<one-line description>"
```
After answer: `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" ""`.

## Ensure Worktree — Failure Recovery

If `git worktree add` fails because the directory already exists (e.g., from a crashed prior run): manually remove `<main-checkout>/<worktree-root>/<ID>/` or run `/n1:n1-clean` to clean up stale worktrees, then retry.

To remove a stale worktree entry without the directory:
```bash
git worktree prune
```

## Ensure Dependencies — Failure Recovery

When setup command fails:

Read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP=auto` AND this is the first attempt (no prior retry in overview.md `## Escalations`): append `worktree setup auto-retry attempted` to `## Escalations`, re-run step 4 once. If retry succeeds: continue. If retry fails (or `MP!=auto`): report stderr and ask:

```
Worktree dependency setup failed. How should I proceed?
1 — Retry setup (a transient install failure usually clears on retry)
2 — Skip and continue anyway
3 — Abort — stop the pipeline
```

- Retry → re-run setup.
- Skip → record in `## Escalations` ("worktree setup skipped by user"), do NOT create marker, continue.
- Abort → record in `## Escalations` and STOP.
