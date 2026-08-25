---
name: n1-pr
description: "Finalize the branch: update docs, push, create or skip PR based on config, and update tracker."
model: sonnet
effort: low
---

# N1 Pull Request Creation

## Overview

Create a PR from the current feature branch. Spawns tech-writer for PR content, then handles push, PR creation via `gh`, and tracker update.

**Announce at start:** "I'm using the n1-pr skill to finalize the branch."

## N1_HOME Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If empty — N1 not configured; warn the user. Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

## Prerequisites

```bash
CURRENT_BRANCH=$(git branch --show-current)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
```

- On default branch → "Switch to a feature branch first." **STOP.**
- Uncommitted changes → commit first (summarize, ask confirmation).

## Standalone Skip Guard

Read `git.prMode` via `n1_config_val '.git.prMode'`:
1. `git.prMode` present → use directly (`"draft"` | `"ready"` | `"skip"`)
2. Else `git.draftPR` is `false` → `"ready"`
3. Else → `"draft"`

If `"skip"`: report "PR mode is set to skip. No push or PR will be created. Run /n1:n1-init to reconfigure." **STOP.**

## Step 1: Collect Information

### Git context:
```bash
git log ${DEFAULT_BRANCH}..HEAD --oneline
git diff ${DEFAULT_BRANCH}...HEAD --stat
```

### N1 memory (if available):

Do NOT read full reports — tech-writer receives paths and reads them itself. Extract only:
- `overview.md` — read in full (small: ticket title, status, key decisions)
- Verdict lines via single Bash call:

```bash
grep -m1 -iE 'verdict' "$N1_HOME/memory/$ID/review.md" 2>/dev/null || true
grep -m1 -iE 'verdict|overall' "$N1_HOME/memory/$ID/qa.md" 2>/dev/null || true
grep -m1 -iE 'verdict|result' "$N1_HOME/memory/$ID/local-testing.md" 2>/dev/null || true
```

Missing grep results are non-blocking — they feed report text only.

### N1 config:
Read from `$N1_HOME/config.json`: `tracker.prefix`, `tracker.mcp`, `git.defaultBranch`, `git.branchPattern`.

### Extract ticket ID:
Parse from branch name using `git.branchPattern` (e.g. branch `TRID-510` + pattern `{prefix}-{id}` → `TRID-510`).

## Step 2: Documentation Update

**Spawn agent:** tech-writer (Phase 1 only). Resolve model for `tech-writer`.

### Doc config:
From `$N1_HOME/config.json` optional `docs` section: `docs.include` (globs), `docs.exclude` (globs), `docs.autoUpdate` (bool, default `false`).

### Mode:
- Called with `docUpdateMode: "autonomous"` (from n1-start) → `autonomous`
- `docs.autoUpdate` is `true` → `autonomous`
- Otherwise → `confirm`

### Spawn tech-writer Phase 1 with:
Default branch, paths to `implementation.md` (if available), git diff stat, doc config (`include`/`exclude`), doc update mode.

### If `confirm` mode:
**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — apply updates and append a Decision Ledger row per `skills/n1-start/ledger.md` (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass via `docUpdateMode: "autonomous"`.

Otherwise present updates and ask: "Apply or skip? (apply/skip)"

### If `autonomous` mode:
Tech-writer applies and commits without prompting.

### No stale docs found:
Proceed to Step 3.

## Step 3: Generate PR Content

**If PR title and body provided as input** (e.g. from n1-start): use directly, skip tech-writer.

**Otherwise (standalone):**

**Spawn agent:** tech-writer. Resolve model.

**Collect inferred-criteria context:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
DQ=$(n1_read_frontmatter "$N1_HOME/memory/$ID/ticket.md" "description_quality" 2>/dev/null || echo "adequate")
[ -z "$DQ" ] && DQ="adequate"
BRAINSTORM_MODE=$(n1_autonomy_val 'brainstorm')
BRAINSTORM_GATE_SKIPPED=false
[ "${BRAINSTORM_MODE:-ask}" = "auto" ] && BRAINSTORM_GATE_SKIPPED=true
```

Spawn tech-writer with: ticket ID, paths to `overview.md`/`review.md`/`qa.md`/`local-testing.md` (if exists), git diff stat, Phase 1 doc update report, `description_quality: $DQ`, `brainstorm_gate_skipped: $BRAINSTORM_GATE_SKIPPED`.

Returns structured PR title and body.

**Autonomy gate:** if `$(n1_autonomy_val 'mechanicalPrompts')` is `auto`, skip the prompt — create PR as composed, append Decision Ledger row (step `pr`, category `mechanical`, tier `C`, tag `[auto]`, reason `mechanicalPrompts=auto`). Pipeline invocations already bypass.

Otherwise: present title/body, ask **"Create PR with this content? (yes/edit/cancel)"**

## Step 4: Push and Create PR

`prMode` already resolved (only `"draft"` or `"ready"` reaches here).

```bash
git push -u origin ${CURRENT_BRANCH}
```

Draft: `gh pr create --title "<title>" --body "<body>" --base ${DEFAULT_BRANCH} --draft`
Ready: same without `--draft`.

Capture and display PR URL.

## Step 5: Update Tracker (if configured)

If `tracker.mcp` is not null:

1. **Move to code review:** `mcp__<tracker.mcp>__<operations.moveStatus>` with `tracker.statuses.codeReview`. Jira: get transition ID first via `getTransitions`. YouTrack: `update_issue` directly.
2. **Add comment:** `mcp__<tracker.mcp>__<operations.addComment>` — body: `PR created: <PR_URL>`

Tracker failures: warn, don't block.

## Step 6: Update Memory

If N1 memory exists: update `overview.md` (mark PR done, add URL), add `docs_updated` list (file, confidence, action), set frontmatter `step: pr`.

## Step 7: Report

Draft mode (**bolded** URL to surface draft state):
```
**PR created (draft):** <PR_URL>
PR #: <number>
Title: <title>
Base: <default branch>
Tracker: <status updated / not configured / failed>
CHECKPOINT: Ready for Tech Lead review.
```

Ready mode: same with `PR created:` (not bolded).

## Step 8: Post-PR Follow-ups

> **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** after the PR exists, any user request that changes code, tests, docs, or config on the branch (rename a flag, tweak a message, "also handle X", address a review comment) is implemented by the **developer agent in fix mode** — never by the orchestrator with Edit/Write/`sed`, and never committed by the orchestrator. This holds even for one-line changes.

Procedure for a follow-up request:
1. Resolve the workspace: read `worktreePath` from `$N1_HOME/active-run.json` (via `jq -r '.worktreePath // empty'`). If the recorded path exists and is not under `/.claude/worktrees/` (external worktree), use it directly. Otherwise, use `<main-checkout>/.claude/worktrees/<ID>` (the worktree is still present — n1-pr no longer removes it).
2. Resolve model for `developer`. Spawn developer with: the user's request verbatim, the branch name and worktree path, `$N1_HOME/memory/<ID>/implementation.md` path, and the directive: "Implement exactly this follow-up on the existing branch. Update any docs that reference the changed behaviour (README, CLI help). Run the relevant tests. Commit with an imperative message and push to `<branch>`. Append a `## Follow-up <N>` section to `implementation.md` (idempotent). Return: commit SHAs + one-line summaries."
3. If the change touches public behaviour (CLI flags, API, config keys): spawn `code-reviewer` on `git diff <pre-follow-up SHA>..HEAD` and route any Critical/High finding back to the developer (max 2 cycles).
4. Post a tracker comment via `mcp__<tracker.mcp>__<operations.addComment>`: `Follow-up pushed to PR: <one-line summary>` (warn, don't block, on failure).

## Integration

**Called by:** n1-start (after review loop + local testing), standalone `/n1:n1-pr`
**Invokes:** n1 agent: tech-writer (Phase 1 doc update + Phase 2 PR content), developer (post-PR follow-ups); inline: git, gh, tracker MCP
