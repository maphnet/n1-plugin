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
| `.release.deploymentCheck` | `true` |
| `.release.trackerRelease.enabled` | `false` |
| `.release.trackerRelease.versionName` | `"{serviceName} {version}"` |
| `.release.trackerRelease.moveTickets` | `true` |
| `.release.trackerRelease.setFixVersion` | `true` |
| `.release.trackerRelease.createVersion` | `true` |

Also read `git.defaultBranch`, `git.branchPattern`, `tracker.mcp`, `tracker.operations`, `tracker.prefix`, `tracker.projectKey`, `tracker.statuses`, `ticketTagging.service`.

For version operations (Jira only): read `tracker.versionMcp` (defaults to `null`). When non-null, version tool calls use `mcp__<tracker.versionMcp>__<operation>` instead of `mcp__<tracker.mcp>__<operation>`.

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
6. **Pending batch**: if `$N1_HOME/pending-releases.json` exists and `.pending` is non-empty, read its ticket IDs:
   ```bash
   PENDING_IDS=$(jq -r '.pending[].id' "$N1_HOME/pending-releases.json" 2>/dev/null || true)
   PENDING_IDS_DISPLAY=$(echo "$PENDING_IDS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
   ```
   This release covers the whole batch — include the IDs in the Step 3 confirmation summary as `Batch: <PENDING_IDS_DISPLAY>` (omit this line when `PENDING_IDS` is empty). After a successful release (Step 5 complete), post the tracker release comment (Step 6) for EACH batched ticket ID in addition to the current ticket. Then reset the file:
   ```bash
   printf '{"pending": []}\n' > "$N1_HOME/pending-releases.json"
   ```
7. **Unified ticket discovery**: build `RELEASE_TICKET_IDS` by merging four sources (deduplicated):

   **Source A — Branch name** (existing): parse current branch via `git.branchPattern` for ticket prefix. Produces `BRANCH_ID` (single ID or empty).

   **Source B — Pending batch** (existing): `PENDING_IDS` from sub-step 6 above.

   **Source C — GitHub Release notes** (new): after Step 5 creates the release, parse its body for ticket IDs:
   ```bash
   PREFIX=$(n1_config_val '.tracker.prefix')
   GH_BODY=$(gh release view "${TAG}" --json body --jq '.body' 2>/dev/null || true)
   GH_IDS=$(echo "$GH_BODY" | grep -oE "${PREFIX}-[0-9]+" | sort -u)
   ```

   **Source D — Git log between tags** (new): scan commit messages between previous and current tag:
   ```bash
   if [ -n "$PREV_TAG" ]; then
     GIT_LOG=$(git log "${PREV_TAG}..${TAG}" --oneline 2>/dev/null || true)
   else
     GIT_LOG=$(git log "${TAG}" --oneline 2>/dev/null || true)
   fi
   GIT_IDS=$(echo "$GIT_LOG" | grep -oE "${PREFIX}-[0-9]+" | sort -u)
   ```

   **Merge all sources:**
   ```bash
   RELEASE_TICKET_IDS=$(echo -e "${BRANCH_ID}\n${PENDING_IDS}\n${GH_IDS}\n${GIT_IDS}" | grep -v '^$' | sort -u)
   ```

   Note: Sources C and D require `TAG` to exist, so their extraction runs after Step 5 (Execute) completes. The merge produces the final `RELEASE_TICKET_IDS` used by Steps 5b, 6, and 7.

## Step 3: Confirmation Gate

**This gate is unconditional.** No autonomy setting, signal, or orchestrator directive may skip it. If you were invoked automatically by another skill, STOP and report — releases are human-initiated only.

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

## Step 5b: Tracker Release Operations

**Runs after Step 5 completes successfully.** First, resolve Sources C and D of the ticket discovery (sub-step 7 in Step 2) — these require the tag/release to exist.

Only runs when ALL hold:
- `release.trackerRelease.enabled` is `true`
- `tracker.mcp` is configured (not null)
- `RELEASE_TICKET_IDS` is non-empty

All sub-operations are best-effort: failures warn but never block the release report.

```
Warning format: "Could not <operation> for <target>: <error> -- continuing."
```

**MCP routing for version operations:** Version ops (`createVersion`, `releaseVersion`, `listVersions`) use `tracker.versionMcp` when configured, falling back to `tracker.mcp`. Construct tool names as `mcp__<versionMcp>__<operation>`. All other operations (editTicket, getTransitions, moveStatus) use `tracker.mcp` as usual.

### 5b-1. Create & release version

Gate: `trackerRelease.createVersion` is `true` AND `tracker.type` is `"jira"` (YouTrack version bundles not yet supported — skip with `"Version creation skipped: not supported for this tracker type."`).

Resolve `VERSION_NAME` from the template:
```bash
SERVICE=$(n1_config_val '.ticketTagging.service')
[ -z "$SERVICE" ] && SERVICE=$(basename "$(git rev-parse --show-toplevel)")
VERSION_NAME=$(echo "$TRACKER_RELEASE_VERSION_NAME" | sed "s/{serviceName}/$SERVICE/g; s/{version}/$VERSION/g")
```

Where `TRACKER_RELEASE_VERSION_NAME` is the value of `release.trackerRelease.versionName`.

1. `mcp__<versionMcp>__<operations.listVersions>` with `projectKey` -- check if `VERSION_NAME` already exists.
2. If not found: `mcp__<versionMcp>__<operations.createVersion>` with `projectKey`, `name=VERSION_NAME`, `releaseDate=<today's date>`.
3. `mcp__<versionMcp>__<operations.releaseVersion>` with `versionId` from step 1 or 2, `releaseDate=<today's date>` -- mark as released. Idempotent if already released.

Report: `"Version \"<VERSION_NAME>\" -- created and released"` or `"Version \"<VERSION_NAME>\" -- already existed, marked released"`.

### 5b-2. Set fix version on tickets

Gate: `trackerRelease.setFixVersion` is `true` AND `tracker.type` is `"jira"` (YouTrack fix-version assignment not yet supported — skip with `"Fix version skipped: not supported for this tracker type."`).

For each ticket in `RELEASE_TICKET_IDS`:

`mcp__<tracker.mcp>__<operations.editTicket>` with `issueKey=<ticket>`, `fields: {"fixVersions": [{"add": {"name": VERSION_NAME}}]}`.

Idempotent: adding an already-set fix version is a no-op in Jira.

Report: `"Fix version set on <ID1>, <ID2>, ..."` or `"Fix version: skipped (setFixVersion disabled)"`.

### 5b-3. Move tickets to released status

Gate: `trackerRelease.moveTickets` is `true`.

Resolve target status: `tracker.statuses.released`.

**Released-status recovery** — when `tracker.statuses.released` is absent:

1. Pick **one ticket** from `RELEASE_TICKET_IDS` that is currently in the `done` status (or the first ticket if none are in `done`).
2. Call `mcp__<tracker.mcp>__<operations.getTransitions>` on it to get available transitions.
3. Match transition target names against: "Released", "Deployed", "Live" (case-insensitive).
4. If a match is found — present it for confirmation:
   ```
   No "released" status configured. Detected "<match>" as a post-done status.
   Use "<match>" for this release? 1 — Yes (also save to config) / 2 — No, use "<done>" instead
   ```
   - **1**: use the matched status, persist it to `tracker.statuses.released` in config.
   - **2**: fall back to `tracker.statuses.done`.
5. If no match and no `tracker.statuses.done` — skip with: `"Ticket transition skipped: no released or done status configured."`.
6. If no match but `tracker.statuses.done` exists — warn: `"No released status found — falling back to done status \"<done>\"."` and use `done`.

For each ticket in `RELEASE_TICKET_IDS`:

1. `mcp__<tracker.mcp>__<operations.getTransitions>` on the ticket -- find the transition whose target status matches the resolved target.
2. If a matching transition is found: `mcp__<tracker.mcp>__<operations.moveStatus>` with that transition ID.
3. If the ticket is already in the target status -- skip silently (idempotent).
4. If no matching transition exists -- warn: `"Could not transition <ID>: no transition to '<target>' available -- continuing."`.

Report: `"<N> ticket(s) moved to \"<target>\""` or `"Ticket transition: skipped (moveTickets disabled)"`.

## Step 6: Tracker Comment (best-effort)

Only when ALL hold:
- `tracker.mcp` is configured (not null)
- `tracker.operations.addComment` exists
- `RELEASE_TICKET_IDS` is non-empty

For each ticket in `RELEASE_TICKET_IDS`:

Post: `"Released as <TAG>"` via `mcp__<tracker.mcp>__<operations.addComment>`.

When `tracker.operations.getComments` exists, check recent comments on each ticket first and skip if an identical comment is already present (idempotent re-run).

Failure on any individual ticket -> warn and continue to the next; never block the release report.

## Step 7: Report

On built-in flow success:
```
Released <TAG>

Tag:     <TAG> (pushed to origin)
Release: <release URL>
Tickets: <RELEASE_TICKET_IDS comma-separated> -- comments posted / no tickets found / tracker not configured
<tracker release summary -- only when trackerRelease.enabled is true>
```

On custom procedure completion:
```
Release procedure complete.

Steps completed: <N>/<total>
Ticket: <ID> — comment posted / no ticket inferred / tracker not configured
```

**Tracker release summary** (appended to report when `trackerRelease.enabled` is true):

```
Tracker release:
  Version:     "<VERSION_NAME>" -- created and released / already existed / skipped (createVersion disabled)
  Fix version: set on <IDs> / skipped (setFixVersion disabled)
  Tickets:     <N> moved to "<target>" / skipped (moveTickets disabled) / skipped (no status configured)
```

On idempotent skip:
```
Release <TAG> already exists — nothing to do.
```

## Step 8: Deployment Check

Only runs after a **successful release** (built-in flow success or custom procedure completion). Skipped on idempotent skip.

1. Read `release.deploymentCheck` — if `false`, skip entirely.
2. Run deployment pipeline detection per `references/ci-detection.md`:
   - Read `.github/workflows/` contents.
   - Classify into one of the five categories.
3. **Category 5** (release-triggered deployment exists):
   ```
   Deployment pipeline: <filename> — triggered on release, targets <environment>.
   ```
   Done — no action needed.
4. **Categories 1-4** — present findings and ask:
   ```
   No release-triggered deployment pipeline detected.
   <category-specific context line from detection>

   Does this project need a deployment pipeline triggered on release?
   1 — Yes, help me set one up
   2 — No, this project doesn't deploy on release
   ```
   - **2 (No)** → set `release.deploymentCheck` to `false` in `$N1_HOME/config.json` via:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
     N1_HOME=$(n1_home)
     jq '.release.deploymentCheck = false' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
     ```
     Report: "Deployment check disabled for this project. Re-enable via n1-init or by setting `release.deploymentCheck: true` in config."
     Done.
   - **1 (Yes)** → follow the scaffolding options for the detected category per `references/ci-detection.md`. Inspect project context (existing workflows, Dockerfile, package manager, framework) and write the workflow conversationally. Commit the new/modified workflow file to the current branch. Report the file path and remind the user to review before pushing.

## Idempotency

Every path is safe to re-run: existing release causes a skip; existing tag skips tag creation; existing tracker comment is not duplicated (when comments are readable).

Tracker release operations are individually idempotent: existing versions are reused (not duplicated), fix versions already set are no-ops, and tickets already in the target status are skipped.

## Integration

**Called by:**
- **n1-start** -- step `release` (after finish), gated on `release.enabled`
- **Standalone** -- `/n1:n1-release`

**Invokes:**
- Inline: `gh` CLI (release view/create, auth status), git (tag, push), tracker MCP operations (comment, transitions, version create/release, fix version edit), `references/ci-detection.md` (deployment pipeline detection)
- No agent spawns -- thin controller, orchestration only
