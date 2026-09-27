# Step 1: Resolve Target

## Prerequisites

- `gh auth status` — if not authenticated AND `prMode` (from Config Read) is not `"skip"`: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.** The local-merge path needs no `gh`: when `prMode` is `"skip"` and `gh` is unauthenticated, skip the PR lookup below and go to Step 2b (local merge).
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.
- **Pending deploy resume:** check whether a deploy is pending for `<ID>`, and validate the recorded SHA before trusting it (it is untrusted frontmatter, not a fresh git query):
  ```bash
  source ~/.n1/preamble.sh
  OV="$N1_HOME/memory/<ID>/overview.md"
  PENDING="$(n1_read_frontmatter "$OV" deploy_pending)"
  SHA="$(n1_read_frontmatter "$OV" deploy_merge_sha)"
  DEFAULT_BRANCH="$(n1_config_val '.git.defaultBranch')"
  SHA_VALID=false
  if [ -n "$SHA" ] && [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] \
      && git merge-base --is-ancestor "$SHA" "${DEFAULT_BRANCH:-main}" 2>/dev/null; then
      SHA_VALID=true
  fi
  echo "deploy-pending:$PENDING sha:$SHA sha-valid:$SHA_VALID"
  ```
  If it prints `deploy-pending:true` with `sha-valid:true`, the merge already happened (in a queue run, or before a declined or failed deploy). Skip the PR lookup, Step 2 and Step 3, and go to Step 4 with `<SHA>` set to that value. Step 4 runs the delivery gate first. If `deploy-pending:true` but `sha-valid:false` (SHA missing, malformed, or not an ancestor of the default branch), do not trust the recorded SHA — fall back to the normal PR/merge lookup below as if nothing were pending.

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → `gh pr view --json ...` (current branch), or `gh pr list --head <branch> --state all --json ...` when not on the branch.
- **No PR found:**
  - `prMode` is `"skip"` → go to Step 2b (local merge) in `02-merge.md`.
  - Otherwise → "No PR found for this branch — run /n1:n1-pr first." **STOP.**
