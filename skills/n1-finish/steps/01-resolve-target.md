# Step 1: Resolve Target

## Prerequisites

- `gh auth status` — if not authenticated: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.**
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.

## Step 1: Resolve Target

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → `gh pr view --json ...` (current branch), or `gh pr list --head <branch> --state all --json ...` when not on the branch.
- **No PR found:** "No PR found for this branch — run /n1:n1-pr first." **STOP.**
