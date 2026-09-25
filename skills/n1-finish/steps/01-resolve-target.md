# Step 1: Resolve Target

## Prerequisites

- `gh auth status` — if not authenticated AND `prMode` (from Config Read) is not `"skip"`: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.** The local-merge path needs no `gh`: when `prMode` is `"skip"` and `gh` is unauthenticated, skip the PR lookup below and go to Step 2b (local merge).
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → `gh pr view --json ...` (current branch), or `gh pr list --head <branch> --state all --json ...` when not on the branch.
- **No PR found:**
  - `prMode` is `"skip"` → go to Step 2b (local merge) in `02-merge.md`.
  - Otherwise → "No PR found for this branch — run /n1:n1-pr first." **STOP.**
