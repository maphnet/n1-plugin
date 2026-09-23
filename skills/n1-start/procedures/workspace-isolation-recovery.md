# Procedure: Workspace Isolation — Recovery

Read this file only when `procedures/workspace-isolation.md` instructs you to (workspace creation fails or unexpected condition encountered).

## Ensure Working Branch — Prompt Texts

Before any user prompt, write pending marker:
```bash
source ~/.n1/root/lib/preamble.sh
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" "<one-line description>"
```
After answer: `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "pending_prompt" ""`.

**Dirty working tree prompt** (on DEFAULT or TARGET exists, with uncommitted changes):
```
You have uncommitted changes. How should I proceed?
1 — Stash changes and switch to '<TARGET>' (run `git stash pop` to restore later)
2 — Carry changes to '<TARGET>' (switch with dirty tree)
3 — Abort — commit or stash manually first
```
Option 1: `git stash push -m "n1: stashed before switching to <TARGET>"`, then switch. Report: "Stashed uncommitted changes. Run `git stash pop` when done."

**Foreign branch prompt** (on a branch that is neither TARGET nor DEFAULT, clean tree):
```
You're on branch '<CURRENT>', not the default ('<DEFAULT>').
1 — Create '<TARGET>' from here
2 — Switch to '<DEFAULT>' and branch '<TARGET>' from there
3 — Keep working on '<CURRENT>'
```

**Combined prompt** (foreign branch + dirty):
```
You're on branch '<CURRENT>' (not '<DEFAULT>') and have uncommitted changes.
1 — Stash changes, switch to '<DEFAULT>', branch '<TARGET>' from there (run `git stash pop` to restore later)
2 — Create '<TARGET>' from '<CURRENT>', carrying uncommitted changes
3 — Abort — handle manually
```

**Mechanical-prompt autonomy (MP=auto) defaults:**
- Dirty tree → option 1 (stash + switch). Ledger: `| start | mechanical | C | [auto] | Dirty tree before branch switch | Stash and switch | Carry, Abort | mechanicalPrompts=auto; stash is reversible | --- |`
- Foreign branch → option 2 (switch to DEFAULT, branch from there). Ledger: `| start | mechanical | B | [auto] | On '<CURRENT>' not default | Branch from default | Branch from here, Stay | default base avoids accidental stacked branches | --- |`
- Combined → option 1 (stash + switch to DEFAULT + branch). Ledger: `| start | mechanical | B | [auto] | Foreign branch + dirty tree | Stash, branch from default | Carry from here, Abort | mechanicalPrompts=auto; both actions reversible | --- |`

The destructive option (Abort) is never auto-selected.

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
