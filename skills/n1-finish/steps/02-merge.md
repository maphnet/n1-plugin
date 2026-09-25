# Step 2: Merge State Machine

> **Polling discipline:** merge-waiting uses `n1_wait_pr_merged` from `lib/poll.sh` — an internal 30s loop bounded to 8-minute chunks per Bash call. Re-invoke until it prints a terminal state or the `waitForMergeMinutes` budget is spent. Never poll one-`gh`-call-per-model-turn.

**Merge permission.** Decide once, before evaluating the PR state:

```bash
source ~/.n1/preamble.sh
if n1_merge_allowed; then echo "merge:allowed"; else echo "merge:denied"; fi
[ -n "${N1_QUEUE_RUN_ID:-}" ] && echo "queue-run:yes"
```

`merge:denied` together with `queue-run:yes` → report "Queue run: merging is disabled (`queue.mergeOnFinish` is not `true`). The ticket stops after PR + CI." **STOP.** This covers both the PR path and Step 2b. The PreToolUse hook would deny the merge command anyway.

Evaluate the PR state:

1. **`MERGED`** → capture the merge commit SHA (`.mergeCommit.oid`). Go to Step 3.
2. **`CLOSED`** (not merged) → report "PR #<n> was closed without merging — nothing to finish. The ticket stays open." **STOP.**
3. **`OPEN`:**
   a. Check CI: `gh pr checks <n> --json name,state,conclusion`. If any check has `conclusion: FAILURE` → "CI is red on PR #<n> — run /n1:n1-ci first." **STOP.**
   b. **PR comment check:** fetch unresolved review threads and pending change requests via a single GraphQL call:
      ```bash
      gh api graphql -f query='
        query($owner:String!,$repo:String!,$pr:Int!) {
          repository(owner:$owner,name:$repo) {
            pullRequest(number:$pr) {
              reviewThreads(first:100) {
                nodes {
                  isResolved
                  comments(first:10) {
                    nodes { author{login} body path line createdAt }
                  }
                }
              }
              reviews(first:50,states:[CHANGES_REQUESTED]) {
                nodes { author{login} body state createdAt }
              }
              latestOpinionatedReviews(first:50) {
                nodes { author{login} state }
              }
            }
          }
        }
      ' -f owner="<owner>" -f repo="<repo>" -F pr=<n>
      ```
      Extract `<owner>` and `<repo>` from `gh repo view --json owner,name --jq '.owner.login,.name'`.

      **What counts as unresolved:**
      - Review threads where `isResolved: false`
      - `CHANGES_REQUESTED` reviews from authors whose `latestOpinionatedReviews` entry is NOT `APPROVED`

      **When nothing is found:** skip silently, proceed to sub-item c.

      **When unresolved items exist,** analyze each inline (no agent spawn):
      1. Read the comment text and the referenced file/line (if inline thread).
      2. Check current code via `git show HEAD:<path>` at the referenced line range to see if the concern was already addressed.
      3. Produce a per-comment recommendation:
         - **Fix** — valid concern not yet addressed. Reasoning explains what needs to change.
         - **Skip** — already addressed in code, outdated (file/line no longer exists), or stylistic nitpick with no functional impact. Reasoning explains why it is safe to skip.

      Present grouped by reviewer:
      ```
      PR #<n> has unresolved reviewer feedback:

      @reviewer1 (CHANGES_REQUESTED):
        1. [path/to/file.ts:25] "Consider using a map here instead of forEach"
           -> Skip: stylistic preference, current implementation is correct.
        2. [path/to/file.ts:89] "This doesn't handle the null case"
           -> Fix: the null guard is still missing at line 89.

      @dependabot:
        3. [package.json:15] "Upgrade lodash to fix CVE-2024-XXXX"
           -> Fix: dependency is still at the vulnerable version.

      Recommendation: <M> comment(s) to address, <K> to skip.
      ```

      Ask inline — "Proceed with merge? (yes / no — fix first)"
      - **yes** → record in memory (`overview.md` `## Finish`): `Comments: <N> unresolved, user approved merge`. Proceed to sub-item c.
      - **no** → "Address the comments, push, then re-run `/n1:n1-finish`." **STOP.**

      **Pagination:** `first:100` threads covers virtually all PRs. If `reviewThreads.pageInfo.hasNextPage` is true, log: "PR has >100 review threads; only the first 100 were checked."

      **API failure:** warn and proceed to sub-item c. Comment check is advisory; never blocks merge due to API errors. Log: "Could not fetch PR review comments — skipping comment check."
   c. If the merge permission printed `merge:allowed` → initiate the merge (once, not per poll). On `merge:denied`, skip to sub-item d and wait for the reviewer's merge:
      ```bash
      gh pr merge <n> --auto --<mergeMethod> --delete-branch
      ```
      `--auto` respects branch protection (required approvals, checks, merge queues). If the command itself is rejected (e.g. auto-merge disabled on the repo and checks pending), retry once with the direct form `gh pr merge <n> --<mergeMethod> --delete-branch`; if that is also rejected, before treating the failure as fatal re-check `gh pr view <n> --json state` — if the PR is `MERGED`, treat the merge as successful and continue to Step 3; otherwise report GitHub's error verbatim and **STOP.**
   d. Bounded wait for merged state — up to `waitForMergeMinutes` total:
      ```bash
      source ~/.n1/preamble.sh
      source "$N1_ROOT/lib/poll.sh"
      n1_wait_pr_merged <n> <remaining-minutes>
      ```
      Repeat the call (subtracting elapsed minutes) while it prints `open` and budget remains.
      - Prints `merged <sha>` → capture SHA, go to Step 3.
      - Prints `closed` → treat as Step 2 case 2 (closed without merging).
      - Budget exhausted, still `open` → "PR #<n> is not merged yet — waiting on reviewer approval. Re-run `/n1:n1-finish` after the merge; the command is idempotent." **STOP.**

## Step 2b: Local Merge (no-PR path, `prMode == "skip"` only)

1. **Worktree context:** if the current toplevel (`git rev-parse --show-toplevel`) contains `/$(n1_worktree_root)/`, resolve the main checkout (`MAIN_CHECKOUT=$(dirname "$(git rev-parse --git-common-dir)")`) and run the default-branch git commands below from `$MAIN_CHECKOUT` — the default branch is checked out there, and `git checkout <defaultBranch>` inside the worktree fails with "already checked out". The clean-tree precondition then applies to the main checkout. Plain checkout: run everything from the current directory.
2. **Preconditions:** `git status --porcelain` must be empty (dirty tree → "Commit or stash changes first." **STOP.**); the feature branch and `git.defaultBranch` must both exist locally.
3. **Test-suite precondition** (run in the feature-branch directory — the worktree, or the plain checkout on `<branch>`): discover the full-suite test command the same way the qa-engineer does (project root: `package.json` `scripts.test`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod` → `go test ./...`, Makefile `test` target — first match wins).
   - **No test configuration found:** note "no test suite detected — skipping test precondition" in the report and proceed.
   - **Test configuration found:**
     ```bash
     <discovered-test-command> 2>&1; SUITE_EXIT=$?
     ```
     Non-zero `SUITE_EXIT` → report the failure output and "Refusing to merge: test suite is failing (exit code <SUITE_EXIT>). Fix failing tests and re-run `/n1:n1-finish`." **STOP.**
4. **Merge** by `mergeMethod`:
   - `squash`: on `<defaultBranch>` (`git checkout <defaultBranch>`; in `$MAIN_CHECKOUT` when in a worktree): `git merge --squash <branch> && git commit -m "<ID>: <ticket title>"`
   - `merge`: on `<defaultBranch>`: `git merge --no-ff <branch> -m "Merge branch '<branch>'"`
   - `rebase`: in the feature-branch directory: `git rebase <defaultBranch>`; then on `<defaultBranch>`: `git merge --ff-only <branch>`
5. **Merge conflict** → `git merge --abort` (or `git rebase --abort` in the feature-branch directory), report the conflicting files, and in a plain checkout switch back to the feature branch. **STOP.**
6. Capture the merge SHA: `git rev-parse HEAD` on `<defaultBranch>`. **No push.** Report: "Merged `<branch>` into `<defaultBranch>` locally. Push manually when ready: `git push origin <defaultBranch>`."
7. Skip Step 3 (`03-deploy.md`) — nothing is on the remote. Deploy status `skipped (local merge)`, smoke `n/a`. Go to Step 4; the tracker comment is the local-merge variant.
