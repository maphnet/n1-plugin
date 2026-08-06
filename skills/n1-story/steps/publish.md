# Step 6: Publish

## Deferred Ticket Creation

Check `story-overview.md` frontmatter for `ticket_deferred`:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
TICKET_DEFERRED=$(n1_read_frontmatter "$MEMORY_DIR/story-overview.md" "ticket_deferred")
```

If `ticket_deferred` is `true`:
- Create the story ticket now (same MCP flow as intake Phase 3 "Create now")
- Adopt the returned ticket ID as final `$ID`
- Rename memory directory if needed:
  ```bash
  mv "$N1_HOME/memory/$PROVISIONAL_ID" "$N1_HOME/memory/$ID"
  MEMORY_DIR="$N1_HOME/memory/$ID"
  ```
- Update `story-overview.md` frontmatter: `ticket: <new-ID>`, `ticket_deferred: false`

## Resolve Design Storage Mode

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
DESIGN_STORAGE=$(n1_config_val '.story.designStorage' "$CONFIG_FILE")
DESIGN_STORAGE="${DESIGN_STORAGE:-article}"
TRACKER_TYPE=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
TRACKER_MCP=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
```

## Article Mode

If `$DESIGN_STORAGE` is `article`:

Check KB availability:
```bash
KB_ENABLED=$(n1_config_val '.kb.enabled' "$CONFIG_FILE")
CREATE_ARTICLE_OP=$(n1_config_val '.tracker.operations.createArticle' "$CONFIG_FILE")
```

If `$KB_ENABLED` is not `true` or `$CREATE_ARTICLE_OP` is empty: fall through to ticket mode with log message: "KB not configured, falling back to ticket description mode."

1. Spawn **tech-writer** to reformat `$MEMORY_DIR/story-design.md` into tracker-friendly markup:
   - **Agent type:** `n1:tech-writer`
   - **YouTrack (`$TRACKER_TYPE` = `youtrack`):** "Reformat this design document for YouTrack Knowledge Base. YouTrack uses Markdown natively. Clean up any formatting that might not render well. Write the result to `$MEMORY_DIR/story-design-formatted.md`."
   - **Jira (`$TRACKER_TYPE` = `jira`):** "Reformat this design document for Confluence. Use HTML content format. Clean up any formatting that might not render well. Write the result to `$MEMORY_DIR/story-design-formatted.md`."

2. Read the formatted content and create article via MCP:
   ```
   mcp__<TRACKER_MCP>__<CREATE_ARTICLE_OP>
   ```
   - **YouTrack:** Parameters: `project` (from `tracker.projectKey`), `summary` ("Design: <Feature Title>"), `content` (formatted design).
   - **Jira/Confluence:** Parameters: `cloudId` (from `tracker.cloudId`), `spaceId` (from `kb.spaceId`), `title` ("Design: <Feature Title>"), `body` (formatted design), `contentFormat` ("html").

3. Capture the returned article ID:
   - **YouTrack:** `idReadable` (e.g., `PROJ-A-12`)
   - **Jira/Confluence:** `id` (numeric page ID)

4. Update story ticket description — prepend design document link:
   - **YouTrack:** prepend `Design document: <idReadable>`
   - **Jira:** prepend `Design document: <confluence-page-url>` (construct from cloudId + page ID)
   Read current description first, prepend the link line.

5. Update `story-overview.md` frontmatter: `article_id: <id>`

6. Clean up `$MEMORY_DIR/story-design-formatted.md`.

## Ticket Description Mode

If `$DESIGN_STORAGE` is `ticket` OR article mode fell through:

1. Spawn **tech-writer** to produce a condensed version:
   - **Agent type:** `n1:tech-writer`
   - **Prompt:** "Produce a condensed ticket description from this design document. Include: goal (2-3 sentences), success criteria (checklist), a table of phases and tasks (title, repo, estimate). Write to `$MEMORY_DIR/story-ticket-description.md`."

2. Update ticket description via `editTicket` operation. Append idempotency marker: `*Design by N1*`.

3. Clean up temp file.

## Local Mode

If `$DESIGN_STORAGE` is `local`:

1. Read `designPath` from config:
   ```bash
   DESIGN_PATH=$(n1_config_val '.story.designPath' "$CONFIG_FILE")
   DESIGN_PATH="${DESIGN_PATH:-docs/design/}"
   ```

2. Copy `$MEMORY_DIR/story-design.md` to `<repo-root>/<DESIGN_PATH>/<ID>-design.md`.

3. Commit:
   ```bash
   git add "<DESIGN_PATH>/<ID>-design.md"
   git commit -m "docs: add design document for $ID"
   ```

4. If tracker ticket exists, update description with a pointer: "Full design: `<DESIGN_PATH>/<ID>-design.md`"

## Update Overview

Update `story-overview.md`:
- Mark Publish checkbox complete
- Update `step: publish`

**Step result:** `outcome: "pass"`, `next_step: "decompose"`
