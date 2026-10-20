# Step 6: Cleanup & Memory

1. **Local branch (runs last in § One Cleanup Call, after the worktree):** branch mode: if on the feature branch, `git checkout <defaultBranch> && git pull` first (local merge: skip `git pull`). Then `git branch -d`, with `-D` only when the tip equals the merged PR head (see tokens below); otherwise keep it and report why.
2. **Remote branch:** `--delete-branch` already handled it on the auto-merge path; on the reviewer-merge path leave remote deletion to the repo's settings — do not force it. Local-merge path: n/a (nothing was pushed).
3. **Worktree (runs before the branch delete in § One Cleanup Call):** only when the current branch is the finished PR's head branch (`HEAD_REF`); an unrelated ticket's worktree is never touched. Removal rules are in the paragraph below the block.
4. **Memory** (when `$N1_HOME/memory/<ID>/` exists) — append to `overview.md`:
   ```markdown
   ## Finish
   - **Merged:** <sha> (<method>, by <auto-merge|reviewer|local merge>)
   - **Comments:** <N unresolved, user approved merge | all resolved | no unresolved comments | check skipped (API error) | n/a (already merged) | n/a (local merge)>
   - **Deploy:** <succeeded <run url> | failed <run url> | skipped (no deploy workflow) | none triggered | skipped (local merge)>
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
ID="<ID>"; case "$ID" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
DB="<defaultBranch>"; LOCAL=<0|1>; HR="<headRefName>"   # HR: the PR's head branch (local merge: the merged feature branch; empty if none)
case "$HR" in *[!A-Za-z0-9._/-]*) echo headref:invalid; exit 1;; esac
case "$DB" in ""|-*|*[!A-Za-z0-9._/-]*) echo db:invalid; exit 1;; esac
case "$LOCAL" in 0|1) ;; *) echo local:invalid; exit 1;; esac
OV="$N1_HOME/memory/$ID/overview.md"
if [ -n "$ID" ] && [ -f "$OV" ]; then
  TMP=$(mktemp "$OV.XXXXXX")
  awk '/^## /{s=/^## (Finish|Pending)\r?$/} !s' "$OV" > "$TMP" && mv "$TMP" "$OV"
  cat >> "$OV" <<'N1_FINISH_BLOCK_9c1e'
<the rendered ## Finish block from item 4>
N1_FINISH_BLOCK_9c1e
  n1_write_frontmatter "$OV" step done
  n1_active_run_clear
  echo memory:done
else echo memory:none; fi
PR="<PR number; empty on local merge>"; OID=""
case "$PR" in *[!0-9]*) echo pr:invalid; exit 1;; esac
[ -n "$PR" ] && OID=$(gh pr view "$PR" --json state,headRefOid -q 'select(.state=="MERGED").headRefOid' 2>/dev/null)   # empty unless merged
BR=$(git rev-parse --abbrev-ref HEAD)
if [ ! -f "$(git rev-parse --show-toplevel)/.git" ]; then   # plain checkout (a linked worktree never checks out the default branch)
  [ "$BR" = "$DB" ] || [ "$BR" != "$HR" ] || { git checkout "$DB" -- && { [ "$LOCAL" = 1 ] || git pull; } || echo checkout:failed; }
fi
n1_finish_cleanup "$HR" "$OID" "$DB"
```

Tokens (from `n1_finish_cleanup` in `lib/config.sh`; print them verbatim in the Report's `Cleanup:` line): `worktree:removed | none | kept-other | kept (<dirty|ignored files|unmerged>) | remove-failed (<error>)` and `branch:deleted | none | kept (<worktree kept|not merged>)`. `kept-other` → the current checkout is another ticket's; nothing was removed (the PR's own branch is still deleted when possible). `checkout:failed` → warn that the default branch could not be checked out or pulled. N1-managed worktrees (under `<main checkout>/$(n1_worktree_root)/`) are removed with `--force`; external worktrees (Orca etc.) are removed only when the tree is clean (ignored files such as `.env` count: `kept (ignored files)`) and HEAD is in the merged PR head (`OID`, else the local default branch), never forced. The branch uses `git branch -d`, falling back to `-D` only when its tip equals the merged PR's `OID` (squash/rebase merge). `kept (unmerged)` with a PR may mean the PR-head lookup failed (`OID` empty). `checkout:failed` implies `branch:kept`; so does a branch still checked out in another worktree (reported as `not merged`). Kept external worktrees are the user's to remove (do not suggest `/n1:n1-clean`); `remove-failed` on an N1-managed one → warn and point at `/n1:n1-clean`; on an external one → warn with the error only.

## Report (final message)

```
Finish complete: <ID> (<ticket title>)

Done: <1-2 lines from ticket title + PR summary>
Ticket: <ID> → <done status | left open (<reason>) | tracker not configured> — <ticket URL | URL unavailable (<reason>)>
PR: <url | none (prMode: skip — push pending: git push origin <defaultBranch>)> — merged (<method>, by <auto-merge|reviewer|local merge>)
Deploy: <succeeded <run url> | failed <run url> | skipped (no deploy workflow) | none triggered | skipped (local merge)>
Verification: <PASS | FAIL | SKIPPED (disabled) | SKIPPED (<reason>) | n/a>
Verification details: <this invocation's validated per-criterion table when `POST_DEPLOY_VERIFICATION_ARTIFACT=true`; otherwise omitted>
Delivery: <pending — runbook: memory/<ID>/runbook.md, resume with /n1:n1-finish <ID> | succeeded (<verified | not verified>) | n/a (delivery.mode is not ssh)>
Cleanup: <the status tokens, e.g. worktree:removed, branch:deleted | worktree:kept (dirty), branch:kept (worktree kept) | worktree:none, branch:none>
Next tickets: <ID title [status]; ... | none | lookup failed (<reason>)>
Next (manual): /n1:n1-release   ← only when release.enabled is true; N1 never runs releases automatically.
```

- **Ticket URL:** overview frontmatter `ticket_url` (`n1_read_frontmatter`); absent → `URL unavailable (<reason>)`.
- **PR URL:** Step 1's `gh pr view` url; fallback overview `pr_url` / `## Pending`.
- **Next tickets:** call `tracker.operations.getIssueLinks` on `tracker.versionMcp` when set, else `tracker.mcp`, for `<ID>`. Tickets this one blocks: Jira — Blocks-type entries with `outwardIssue`; YouTrack — relation `blocks` (not `is blocked by`). Use title/status from the entry when present, else `readTicket` per link. No such links → `none`. Op not configured or call error → `lookup failed (<reason>)`; warn only, never block. Issue it in parallel with the cleanup call (§ One Cleanup Call).
- Print this summary on every completion path (including already-merged / already-closed re-runs and the runbook-pending path), before release routing in both `mechanicalPrompts` modes. Non-complete exits keep their stop message below and do NOT print it.

<!-- n1-release is never invoked automatically regardless of autonomy mode (NP-71). The steps below are always interactive/suggestion-only. -->
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
- **n1-start** — step `finish` (after CI watch), gated on `n1_merge_allowed` (queue children with `queue.mergeOnFinish` only)
- **Standalone** — `/n1:n1-finish`, `/n1:n1-finish TRID-510`, `/n1:n1-finish #123`

**Invokes:**
- Inline: `gh` CLI (pr view/checks/merge, run list/view), git, tracker MCP operations
- Dispatches `post-deploy-verifier` only after a successful watched deployment; otherwise thin controller orchestration only
