---
name: n1-release
description: "Release a version: create git tag and GitHub Release. Usage: /n1:n1-release"
model: sonnet
effort: low
---

# N1 Release

## Overview

Guide the user through releasing a version of the project. Creates a git tag and GitHub Release (built-in flow) or walks through a custom markdown procedure with placeholder substitution.

Standalone invocation is the primary pattern -- no ticket argument required. Pipeline step wiring exists but defaults off (`release.enabled: false`).

**Announce at start:** "I'm using the n1-release skill to create a release."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty -- N1 is not configured; warn the user and STOP.

## Config Read

Read the `release` block via `n1_config_val`, applying defaults when keys are absent:

| Key | Default |
|-----|---------|
| `.release.enabled` | `false` |
| `.release.tagPrefix` | `"v"` |
| `.release.procedure` | `null` |
| `.release.draft` | `false` |

Also read `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`.

`release.enabled` gates only the pipeline step -- standalone invocation proceeds regardless.

## Step Mode Detection

When invoked from `n1-start --step release`, the orchestrator passes step-mode context (`<ID>`, `N1_RUN_ID`). Standalone invocation asks/reports inline.

## Prerequisites

- `gh auth status` -- if not authenticated: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.**

## Step 1: Branch Check

```bash
CURRENT=$(git branch --show-current)
DEFAULT=$(n1_config_val '.git.defaultBranch')
```

- **`CURRENT == DEFAULT`** -- proceed silently.
- **`CURRENT != DEFAULT`** -- ask:
  ```
  You're on branch `<CURRENT>`, not `<DEFAULT>`. Release from here?
  1 -- Yes
  2 -- No, switch to <DEFAULT> first
  ```
  If 2 -> report and STOP.

## Step 2: Resolve Release Metadata

1. **Version**: read `.version` from `.claude-plugin/plugin.json` via Bash:
   ```bash
   VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
   ```
2. **Marketplace version**: read `.version` (or `.plugins[0].version`) from `.claude-plugin/marketplace.json`:
   ```bash
   MKT_VERSION=$(jq -r '.plugins[0].version // .version' .claude-plugin/marketplace.json)
   ```
3. **TAG**: concatenate `tagPrefix + VERSION`:
   ```bash
   TAG_PREFIX=$(n1_config_val '.release.tagPrefix')
   TAG="${TAG_PREFIX}${VERSION}"
   ```
4. **Previous tag**: resolve from local git tags first, fall back to gh:
   ```bash
   PREV_TAG=$(git tag --list "${TAG_PREFIX}*" --sort=-version:refname | head -1)
   if [ -z "$PREV_TAG" ]; then
     PREV_TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
   fi
   # Show "(none — first release)" when nothing found
   ```
5. **Merge SHA**: attempt to read from `$N1_HOME/memory/<ID>/overview.md` `## Finish` section if a memory directory exists for the inferred ticket ID (parsed from branch name via `git.branchPattern`). Otherwise empty string.

## Step 3: Confirmation Gate

Always shown before any side-effecting action:

```
Ready to release:

  Version:      <TAG>  (from .claude-plugin/plugin.json)
  Previous tag: <PREV_TAG or "(none — first release)">
  Branch:       <CURRENT>
  <condition lines>

Proceed with release?
1 — Yes
2 — No
```

Condition lines (informational -- no hard blocks):
- `plugin.json == marketplace.json (<VERSION>)` -- versions match
- `plugin.json / marketplace.json versions differ (plugin.json: <VERSION>, marketplace.json: <MKT_VERSION>)` -- mismatch warning
- `Merge SHA: <sha>` -- found in overview.md
- `No merge SHA found (standalone run — not post-finish)` -- not available

If 2 -> STOP.

## Step 4: Idempotency Check

```bash
if gh release view "${TAG}" &>/dev/null; then
  # Release already exists
fi
```

If release already exists -> report "Release `<TAG>` already exists -- nothing to do." and STOP (this is success, not failure).

Also check local tag:
```bash
git tag -l "${TAG}"
```

If local tag exists but no GitHub release -> proceed to release creation (skip the tag step, create the release).

## Step 5: Execute

### Built-in flow (when `procedure` is null)

```bash
# 1. Create annotated git tag (skip if tag already exists locally)
if ! git tag -l "${TAG}" | grep -q .; then
  git tag -a "${TAG}" -m "Release ${TAG}" ${MERGE_SHA:-HEAD}
fi

# 2. Push tag
git push origin "${TAG}"

# 3. Create GitHub release with --verify-tag to ensure tag matches
gh release create "${TAG}" --generate-notes --verify-tag
# Add --draft if release.draft is true
```

Report the release URL from `gh release view "${TAG}" --json url --jq '.url'` on success.

### Custom procedure flow (when `procedure` is set)

1. **Substitute placeholders** in the `procedure` text:
   - `{{RELEASE_TAG}}` -> `TAG` value (e.g. `v2.29.0`)
   - `{{VERSION}}` -> bare version string (e.g. `2.29.0`)
   - `{{MERGE_SHA}}` -> merge commit SHA (empty string when not found)
   - `{{TICKET_ID}}` -> ticket ID inferred from branch name (empty string when not found)

2. **Parse** the markdown into steps: split on top-level numbered list items (`^[0-9]+\.`) or `##`/`###` headings. Each chunk is one step. Sub-bullets within a step are context, not separate steps.

3. **Walk each step** in order:
   - **Shell step** (contains backtick inline code or a fenced code block) -> extract command(s) and ask:
     ```
     Step N: <step text>
     Command: `<command>`
     Run this?
     1 — Yes
     2 — Skip
     3 — Abort
     ```
     On Yes -> execute via Bash, show stdout/stderr. On non-zero exit -> report failure, ask: `1 — Retry / 2 — Skip / 3 — Abort`.
   - **Manual step** (no shell command) -> show text and ask:
     ```
     Step N: <step text>
     Done?
     1 — Yes, continue
     2 — Abort
     ```

4. **On abort** at any step -> report which step was abandoned, remind the user of what ran and what didn't, leave cleanup to the user.

## Step 6: Tracker Comment (best-effort)

Only when ALL hold:
- `tracker.mcp` is configured (not null)
- `tracker.operations.addComment` exists
- A ticket ID can be inferred from branch name (`git branch --show-current` parsed against `git.branchPattern`)

Post: `"Released as <TAG>"` via `mcp__<tracker.mcp>__<operations.addComment>`.

When `tracker.operations.getComments` exists, check recent comments first and skip if an identical comment is already present (idempotent re-run).

Failure -> warn and continue; never block the release report.

## Step 7: Report

On built-in flow success:
```
Released <TAG>

Tag:     <TAG> (pushed to origin)
Release: <release URL>
Ticket:  <ID> — comment posted / no ticket inferred / tracker not configured
```

On custom procedure completion:
```
Release procedure complete.

Steps completed: <N>/<total>
Ticket: <ID> — comment posted / no ticket inferred / tracker not configured
```

On idempotent skip:
```
Release <TAG> already exists — nothing to do.
```

## Idempotency

Every path is safe to re-run: existing release causes a skip; existing tag skips tag creation; existing tracker comment is not duplicated (when comments are readable).

## Integration

**Called by:**
- **n1-start** -- step `release` (after finish), gated on `release.enabled`
- **Standalone** -- `/n1:n1-release`

**Invokes:**
- Inline: `gh` CLI (release view/create, auth status), git (tag, push), tracker MCP operations
- No agent spawns -- thin controller, orchestration only
