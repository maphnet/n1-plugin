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

### YouTrack

Check if `createArticle` operation exists in config:
```bash
CREATE_ARTICLE_OP=$(n1_config_val '.tracker.operations.createArticle' "$CONFIG_FILE")
```

If present:
1. Spawn **tech-writer** to reformat `$MEMORY_DIR/story-design.md` into tracker-friendly markup:
   - **Agent type:** `n1:tech-writer`
   - **Prompt:** "Reformat this design document for YouTrack Knowledge Base. YouTrack uses Markdown natively. Clean up any formatting that might not render well. Write the result to `$MEMORY_DIR/story-design-formatted.md`."

2. Read the formatted content and create article via MCP:
   ```
   mcp__<TRACKER_MCP>__create_article
   ```
   Parameters: `project` (from `tracker.project` config), `summary` ("Design: <Feature Title>"), `content` (formatted design).

3. Capture the returned article `idReadable` (e.g., `PROJ-A-12`).

4. Update story ticket description — prepend `Design document: <idReadable>`:
   ```
   mcp__<TRACKER_MCP>__update_issue
   ```
   Read current description first, prepend the article link line.

5. Update `story-overview.md` frontmatter: `article_id: <idReadable>`

6. Clean up `$MEMORY_DIR/story-design-formatted.md`.

If `createArticle` operation is absent: fall through to ticket mode.

### Jira

Check if Confluence MCP is available. If yes, create page and link via remote links API. If not, fall through to ticket mode with a log message: "Confluence MCP not available, falling back to ticket description mode."

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
