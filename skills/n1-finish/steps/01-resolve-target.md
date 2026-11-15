# Step 1: Resolve Target

**Already run at entry:** the SKILL.md entry call printed `gh:` (auth status), the pending-deploy check below (`deploy-pending:` line, when `<ID>` was known; with a PR number argument the PR is looked up first and `<ID>` is derived from its head branch) and the current `branch=` and the PR lookup (JSON, or `pr:none`; when `<ID>` was given while on another branch the entry looked the PR up by head branch). Apply the rules below to those lines. Run a lookup here on its own only when the entry call skipped it (`id=` was empty at entry and is resolved afterwards) or printed `pr:none`.

## Run marker (always first, before any merge or push)

Mark this session as an N1 run so the merge-deny hook keeps gating it, on every path (PR, Step 2b, resume). It keeps an existing pointer. Must print `marker:keyed`; `marker:unkeyed` means no session id, so the hook cannot see it (report that); `marker:failed` is a **STOP** (marker not written). Every **STOP** in any step first runs `n1_active_run_clear_if n1-finish` (clears only the pointer this marker wrote; Step 6 does it on success).

```bash
source ~/.n1/preamble.sh; n1_finish_mark "<ID>"
```

## Prerequisites

- `gh auth status` — if not authenticated AND `prMode` (printed at entry) is not `"skip"`: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.** The local-merge path needs no `gh`: when `prMode` is `"skip"` and `gh` is unauthenticated, skip the PR lookup below and go to Step 2b (local merge).
- Resolve `<ID>`: explicit argument, else parse from the current branch name using `git.branchPattern` (same extraction as n1-pr Step 1). A `#123`/`123` argument selects a PR number directly instead.
- **Queue final PR (N1-446, N1-462):** when the PR's `headRefName` starts with `queue/`, there is no ticket: `<ID>` stays empty (the entry derived none and printed `queue-key:<QK>`, the state key for the ssh delivery only), the entry forced `handoff:no` and listed `steps/07-queue-chain.md`. A delivery recorded under `<QK>` (entry printed `deploy-pending:true` with `sha-valid:true`) skips Step 2 and Step 3 as the resume below does (keep the PR JSON: Step 7 needs the final PR URL and number). Otherwise go to Step 2 (merge check). When the head starts with `queue/` but no `queue-key:` was printed (no PR argument), STOP and ask for `/n1:n1-finish <PR#>`. Then follow `steps/07-queue-chain.md`: the chain command, § Queue deploy (Step 3 watch, Step 4 queue subset) and § Close landed children, then Step 6. Step 5 never runs on this path.
- **Pending deploy resume:** check whether a deploy is pending for `<ID>`, and validate the recorded SHA before trusting it (it is untrusted frontmatter, not a fresh git query):
  ```bash
  source ~/.n1/preamble.sh
  case "<ID>" in *[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
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
  If it prints `deploy-pending:true` with `sha-valid:true`, the merge already happened (before a declined or failed deploy, or in a headless run). Skip the PR lookup, Step 2 and Step 3, and go to Step 4 with `<SHA>` set to that value. Step 4 runs the delivery gate first. If `deploy-pending:true` but `sha-valid:false` (SHA missing, malformed, or not an ancestor of the default branch), do not trust the recorded SHA — fall back to the normal PR/merge lookup below as if nothing were pending.

- **PR number argument** → `gh pr view <n> --json number,state,mergedAt,mergeCommit,url,headRefName,baseRefName`.
- **No argument / ticket ID** → the entry's lookup (several head-branch matches: a single OPEN PR wins, else a single MERGED one). On `pr:ambiguous <numbers>`, ask the user which PR to finish (list the numbers), then continue with `gh pr view <n>`; never guess. Only on `pr:none` retry manually with `gh pr list --head <branch> --state all --json ...`.
- **No PR found:**
  - Current branch (the entry's `branch=` line) starts with `spike/` → "Spike branches are never merged; nothing to finish." **STOP.**
  - `prMode` is `"skip"` → go to Step 2b (local merge) in `02-merge.md`.
  - Otherwise → "No PR found for this branch — run /n1:n1-pr first." **STOP.**
