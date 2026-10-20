# Step 6: Cleanup & Memory

1. **Local branch (branch mode, merged PR):** if currently on the feature branch: `git checkout <defaultBranch> && git pull`. Then `git branch -d <branch>` — safe delete only; if `-d` refuses (unmerged from the local default's perspective, e.g. squash merge before pull), leave the branch and note why. Never `-D`. Local-merge path: already on `<defaultBranch>` — skip `git pull` (the merge is local-only and unpushed); `-d` refusing after a squash is expected — keep the branch and note it.
2. **Remote branch:** `--delete-branch` already handled it on the auto-merge path; on the reviewer-merge path leave remote deletion to the repo's settings — do not force it. Local-merge path: n/a (nothing was pushed).
3. **Worktree:** If the current toplevel (`git rev-parse --show-toplevel`) contains `/$(n1_worktree_root)/`, use `worktree.cleanup` (read at entry). If it is `"after-pr"` or `"after-merge"`, the PR has already been merged — both values mean **remove the worktree now**: switch to the main checkout first (`MAIN_CHECKOUT=$(dirname "$(git rev-parse --git-common-dir)")`), then `git worktree remove <path> --force`. Success → "Worktree `<ID>` removed." Failure → warn "Worktree removal failed: `<error>`", point at `/n1:n1-clean`.
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer|local merge>)
   - **Comments:** <N unresolved, user approved merge | all resolved | no unresolved comments | check skipped (API error) | n/a (already merged) | n/a (local merge)>
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered | skipped (local merge)>
   - **Verification:** <PASS | FAIL | SKIPPED (disabled) | SKIPPED (<reason>) | n/a>
   - **Verification details:** when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`, this invocation's validated per-criterion table from `memory/<ID>/post-deploy-verification.md` (include status, concise evidence, and reason; exclude dev-access contents, credentials, raw commands, and raw command output); otherwise omit this line.
   - **Delivery:** <pending (runbook: memory/<ID>/runbook.md) | succeeded (<verified | not verified>) | n/a (delivery.mode is not ssh)>
   - **Ticket:** <moved to <done status> | left open (<reason>) | tracker not configured>
   pr_url: <PR URL from the `## Pending` section being removed below; omit this line on the local-merge path, which has no PR>
   ```
   If a `## Finish` section already exists, replace it (idempotent upsert, never duplicate), carrying over the `- **Delivery:**` value that Step 4's delivery gate (`03b-ssh-deploy.md`) recorded — never drop or rewrite a pending/succeeded delivery as n/a. Only when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`, upsert the full validated verification table from this invocation's `post-deploy-verification.md` in `## Finish`; otherwise omit verification details and never read an existing artifact. Do not summarize away `PASS`, `FAIL`, or `SKIPPED` reasons. Also delete the `## Pending` section (the merge is no longer pending), set frontmatter `step: done`, and clear the active-run pointer (idempotent — safe even when n1-start also clears it in FINALIZE MEMORY). If finish exits without a merge (timeout paths), instead set `step` to `finish` (not `done`) and update only its `last_checked` line with `date -u +%Y-%m-%dT%H:%M:%SZ`. Standalone without memory: skip silently.

## One Cleanup Call

On successful completion, run items 4, 1 and 3 as a single Bash call: memory first (absolute `$N1_HOME` paths), then the worktree, then the branch (the branch cannot be deleted while a linked worktree still has it checked out, so worktree removal precedes `git branch -d`). Issue the Report's `getIssueLinks` lookup in parallel in the same turn. The `## Finish` block's `- **Delivery:**` value comes from this run's delivery gate outcome (03b rewrites overview after entry read it); fall back to the overview read at entry only when the gate did not run. Each part is independent (`;`, never `&&`) and prints its own status line for the Report's `Cleanup:` field. Set `LOCAL=1` on the local-merge path (skip `git pull`), else `0`. Pick a heredoc delimiter that does not occur in the block (change `N1_FINISH_BLOCK_9c1e` if it does).

```bash
source ~/.n1/preamble.sh
ID="<ID>"; case "$ID" in ''|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
DB="<defaultBranch>"; LOCAL=<0|1>
OV="$N1_HOME/memory/$ID/overview.md"
if [ -f "$OV" ]; then
  TMP=$(mktemp "$OV.XXXXXX")
  awk '/^## /{s=/^## (Finish|Pending)\r?$/} !s' "$OV" > "$TMP" && mv "$TMP" "$OV"
  cat >> "$OV" <<'N1_FINISH_BLOCK_9c1e'
<the rendered ## Finish block from item 4>
N1_FINISH_BLOCK_9c1e
  n1_write_frontmatter "$OV" step done
  n1_active_run_clear
  echo memory:done
else echo memory:none; fi
BR=$(git rev-parse --abbrev-ref HEAD); TOP=$(git rev-parse --show-toplevel)
MAIN_CHECKOUT=$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)")
if [ -f "$TOP/.git" ]; then   # linked worktree: never checkout the default branch here
  W=$(n1_config_val '.worktree.cleanup'); RM=0
  case "$TOP" in */"$(n1_worktree_root)"/*) { [ "$W" = after-pr ] || [ "$W" = after-merge ]; } && RM=1;; esac
  if [ "$RM" = 1 ]; then cd "$MAIN_CHECKOUT" && git worktree remove "$TOP" --force && echo worktree:removed || echo worktree:kept; else echo worktree:kept; fi
else
  [ "$BR" = "$DB" ] || { git checkout "$DB"; [ "$LOCAL" = 1 ] || git pull; }
  echo worktree:none
fi
if [ "$BR" != "$DB" ] && [ "$BR" != HEAD ]; then git branch -d "$BR" >/dev/null 2>&1 && echo branch:deleted || echo branch:kept; else echo branch:none; fi
```

`worktree:kept` after a failed removal → warn "Worktree removal failed", point at `/n1:n1-clean`. `branch:kept` → note that `-d` refused (never `-D`). An external worktree (`n1_is_external_worktree`) is outside `/$(n1_worktree_root)/`, so it stays `worktree:kept`.

## Report (final message)

```
Finish complete: <ID> (<ticket title>)

Done: <1-2 lines from ticket title + PR summary>
Ticket: <ID> → <done status | left open (<reason>) | tracker not configured> — <ticket URL | URL unavailable (<reason>)>
PR: <url | none (prMode: skip — push pending: git push origin <defaultBranch>)> — merged (<method>, by <auto-merge|reviewer|local merge>)
Deploy: <succeeded <run url> | failed <run url> | skipped (not configured) | none triggered | skipped (local merge)>
Verification: <PASS | FAIL | SKIPPED (disabled) | SKIPPED (<reason>) | n/a>
Verification details: <this invocation's validated per-criterion table when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`; otherwise omitted>
Delivery: <pending — runbook: memory/<ID>/runbook.md, resume with /n1:n1-finish <ID> | succeeded (<verified | not verified>) | n/a (delivery.mode is not ssh)>
Cleanup: <branch deleted | branch kept (<reason>) | worktree removed | worktree kept (<reason>) — run /n1:n1-clean | nothing to do>
Next tickets: <ID title [status]; ... | none | lookup failed (<reason>)>
Next (manual): /n1:n1-release   ← only when release.enabled is true; N1 never runs releases automatically.
```

- **Ticket URL:** overview frontmatter `ticket_url` (`n1_read_frontmatter`); absent → `URL unavailable (<reason>)`.
- **PR URL:** Step 1's `gh pr view` url; fallback overview `pr_url` / `## Pending`.
- **Next tickets:** call `tracker.operations.getIssueLinks` on `tracker.versionMcp` when set, else `tracker.mcp`, for `<ID>`. Tickets this one blocks: Jira — Blocks-type entries with `outwardIssue`; YouTrack — relation `blocks` (not `is blocked by`). Use title/status from the entry when present, else `readTicket` per link. No such links → `none`. Op not configured or call error → `lookup failed (<reason>)`; warn only, never block. Issue it in parallel with the cleanup call (§ One Cleanup Call).
- Print this summary on every completion path (including already-merged / already-closed re-runs and the runbook-pending path), before release routing in both `mechanicalPrompts` modes. Non-complete exits keep their stop message below and do NOT print it.

<!-- tailChain has no effect here: n1-release is never invoked automatically regardless of autonomy mode (NP-71). The steps below are always interactive/suggestion-only. -->
**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, use the `mechanicalPrompts` value printed at entry; only when it is missing, read it via Bash (source `lib/config.sh` first):

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

**If `MP` is `auto`:** skip the question below (the report's `Next (manual)` line already points at `/n1:n1-release`).

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
- **n1-start** — step `finish` (after CI watch), gated on `n1_finish_enabled` (queue children: `queue.mergeOnFinish`; interactive: `finishWork.enabled`)
- **Standalone** — `/n1:n1-finish`, `/n1:n1-finish TRID-510`, `/n1:n1-finish #123`

**Invokes:**
- Inline: `gh` CLI (pr view/checks/merge, run list/view), git, tracker MCP operations
- Dispatches `post-deploy-verifier` only after a successful watched deployment; otherwise thin controller orchestration only
