# Step 6: Tracker Comment (best-effort)

Only when ALL hold:
- `tracker.mcp` is configured (not null)
- `tracker.operations.addComment` exists
- `RELEASE_TICKET_IDS` is non-empty

For each ticket in `RELEASE_TICKET_IDS`:

Post: `"Released as <TAG>"` via `mcp__<tracker.mcp>__<operations.addComment>`.

When `tracker.operations.getComments` exists, check recent comments on each ticket first and skip if an identical comment is already present (idempotent re-run).

Failure on any individual ticket -> warn and continue to the next; never block the release report.

# Step 7: Report

On built-in flow success:
```
Released <TAG>

Tag:     <TAG> (pushed to origin)
Release: <release URL>
Tickets: <RELEASE_TICKET_IDS comma-separated> -- comments posted / no tickets found / tracker not configured
<tracker release summary -- only when tracker.type is "jira" and RELEASE_TICKET_IDS is non-empty>
```

On custom procedure completion:
```
Release procedure complete.

Steps completed: <N>/<total>
Ticket: <ID> — comment posted / no ticket inferred / tracker not configured
```

**Tracker release summary** (appended to report when `tracker.type` is `"jira"` and Step 5b ran):

```
Tracker release:
  Version:     "<VERSION_NAME>" -- created and released / already existed / skipped (jc-mcp not configured) / skipped (createVersion disabled)
  Fix version: set on <IDs> / skipped (setFixVersion disabled) / skipped (jc-mcp not configured)
  Tickets:     <N> moved to "<target>" / skipped (moveTickets disabled) / skipped (no status configured)
```

On idempotent skip:
```
Release <TAG> already exists — nothing to do.
```

# Step 8: Deployment Check

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
     N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
     source "$N1_ROOT/lib/config.sh"
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
