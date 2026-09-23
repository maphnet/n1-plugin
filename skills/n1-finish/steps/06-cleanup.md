# Step 6: Cleanup & Memory

1. **Local branch (branch mode, merged PR):** if currently on the feature branch: `git checkout <defaultBranch> && git pull`. Then `git branch -d <branch>` — safe delete only; if `-d` refuses (unmerged from the local default's perspective, e.g. squash merge before pull), leave the branch and note why. Never `-D`.
2. **Remote branch:** `--delete-branch` already handled it on the auto-merge path; on the reviewer-merge path leave remote deletion to the repo's settings — do not force it.
3. **Worktree:** If the current toplevel (`git rev-parse --show-toplevel`) contains `/$(n1_worktree_root)/`, read `worktree.cleanup` from config. If it is `"after-pr"` or `"after-merge"`, the PR has already been merged — both values mean **remove the worktree now**: switch to the main checkout first (`MAIN_CHECKOUT=$(dirname "$(git rev-parse --git-common-dir)")`), then `git worktree remove <path> --force`. Success → "Worktree `<ID>` removed." Failure → warn "Worktree removal failed: `<error>`", point at `/n1:n1-clean`.
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer>)
   - **Comments:** <N unresolved, user approved merge | all resolved | no unresolved comments | check skipped (API error) | n/a (already merged)>
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
   - **Smoke:** <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed) | n/a>
   - **Ticket:** <moved to <done status> | left open (<reason>) | tracker not configured>
   ```
   If a `## Finish` section already exists, replace it (idempotent upsert, never duplicate). Set frontmatter:
   ```bash
   source ~/.n1/preamble.sh
   source "$N1_ROOT/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "done"
   ```
   Also delete the `## Pending` section from overview.md if present (the merge is no longer pending). If finish exits without a merge (timeout paths), instead set `step` to `finish` (not `done`) and update only its `last_checked` line with `date -u +%Y-%m-%dT%H:%M:%SZ`.

   Also clear the active-run pointer on successful completion (idempotent — safe even when n1-start also clears it in FINALIZE MEMORY):
   ```bash
   source ~/.n1/preamble.sh
   n1_active_run_clear
   ```

   Standalone without memory: skip silently.

## Report (final message)

```
Finish complete.

PR: <url> — merged (<method>, by <auto-merge|reviewer>)
Deploy: <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered>
Smoke: <passed | failed (<details>) | skipped (not configured) | skipped (deploy failed) | n/a (mode is not smoke)>
Ticket: <ID> → <done status> / left open (<reason>) / tracker not configured
Cleanup: <branch deleted | branch kept (<reason>) | worktree removed | worktree kept (<reason>) — run /n1:n1-clean | nothing to do>
Next (manual): /n1:n1-release   ← only when release.enabled is true; N1 never runs releases automatically.
```

<!-- tailChain has no effect here: n1-release is never invoked automatically regardless of autonomy mode (NP-71). The steps below are always interactive/suggestion-only. -->
**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, read the autonomy setting via Bash (source `lib/config.sh` first):

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

**If `MP` is `auto`:** skip the question below and instead print:

```
Work complete. If you're ready to publish a release, run /n1:n1-release.
```

Write a Decision Ledger row to overview.md:
`| finish | mechanical | C | [auto] | Release now? | Suggest /n1:n1-release | Ask user | mechanicalPrompts=auto | --- |`

**If `MP` is `ask` (default):** ask:

```
Release this now?
1 — Now: run /n1:n1-release (I will suggest it; you invoke it)
2 — Later: nothing recorded
3 — Batch: queue this ticket for the next release
```

- **1** → report `Next: /n1:n1-release` and STOP — do NOT invoke it yourself; releases are human-initiated.
- **2** → nothing to do.
- **3** → read `<N1_ROOT>/skills/n1-finish/references/release-batching.md` for the append procedure.

On non-complete exits, state exactly what stopped the flow and what the user should do (re-run command, fix CI, resolve conflict).

## Idempotency

Every path is safe to re-run: already-merged PR skips the merge; already-closed ticket skips the status move; already-present comment is not duplicated (when comments are readable); deleted branch/worktree cleanup steps no-op.

## Integration

**Called by:**
- **n1-start** — step `finish` (after CI watch), gated on `finishWork.enabled`
- **Standalone** — `/n1:n1-finish`, `/n1:n1-finish TRID-510`, `/n1:n1-finish #123`

**Invokes:**
- Inline: `gh` CLI (pr view/checks/merge, run list/view), git, tracker MCP operations
- No agent spawns — thin controller, orchestration only
