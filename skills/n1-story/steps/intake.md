# Step 1: Intake

## Phase 1: Raw Data Fetch

Spawn **intake-agent** to fetch raw ticket data.

### If `$INPUT_TYPE` is `ticket`:

Resolve tracker operations:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
TRACKER_TYPE=$(n1_config_val '.tracker.type' "$CONFIG_FILE")
TRACKER_MCP=$(n1_config_val '.tracker.mcp' "$CONFIG_FILE")
```

Read the operations map and spawn intake-agent using the Agent tool:
- **Agent type:** `n1:intake-agent`
- **Prompt:** Include the tracker MCP prefix (`mcp__${TRACKER_MCP}__`), the read operation name, and the ticket ID. Instruct the agent to also extract any existing subtasks and linked articles/documents from the ticket.
- **Output:** Agent writes raw content to `$MEMORY_DIR/ticket.md` with `<!-- intake: raw -->` sentinel.

Parse the `intake-result:` line from the agent's return for `title` and `tags`.

Set `$ID` to the ticket ID from the input.

### If `$INPUT_TYPE` is `braindump` or `file`:

For `file`: read the file content.
For `braindump`: use the raw input text.

Spawn intake-agent with the text content. Agent writes raw `ticket.md`.

Parse the `intake-result:` line for `title`.

Set provisional `$ID` from a slug of the title (lowercase, hyphens, max 40 chars): `story-<slug>`.

## Phase 2: Product Analyst

Spawn **product-analyst** with a **story-level directive**:

- **Agent type:** `n1:product-analyst`
- **Prompt directives:**
  - "This is a STORY-LEVEL intake, not a single task. Extract the high-level goal and success criteria, NOT implementation-ready acceptance criteria."
  - "Assess whether this scope represents a genuine multi-task story or a single task. Return `scope: story` or `scope: single-task`."
  - Path to raw `ticket.md`: `$MEMORY_DIR/ticket.md`
  - "Write structured output to `$MEMORY_DIR/ticket.md`, overwriting the raw version."
- **Compact return:** `scope: <story|single-task>, title: <title>, ambiguities: <count>`

### Scope Redirect

If product-analyst returns `scope: single-task`:

Present to user: "This looks like a single task rather than a multi-task story. Would you like to run `/n1:n1-start` instead? (1) Yes — switch to n1-start (2) No — continue as story"

If user chooses Yes: tell the user to run `/n1:n1-start <their-input>` and **STOP** (emit step result with `outcome: "redirect"`).

## Phase 3: Ticket Creation (brain-dump/file only)

If `$INPUT_TYPE` is `braindump` or `file` AND tracker is configured:

Ask user: "Would you like to create a story ticket in the tracker now, or after the design is complete? (1) Create now (2) After design (3) No ticket"

### If "Create now":
Read tracker config. Create ticket via MCP:

For YouTrack:
```
mcp__<tracker.mcp>__create_issue with project, summary=<title>, description=<structured content from ticket.md>
```

For Jira:
```
mcp__<tracker.mcp>__createJiraIssue with cloudId, projectKey, summary=<title>, description=<content>, issueTypeName="Story"
```

Adopt the returned ticket ID as final `$ID`. If a provisional memory directory already exists, rename it:
```bash
mv "$N1_HOME/memory/$PROVISIONAL_ID" "$N1_HOME/memory/$ID"
```

Optionally assign to creator (same pattern as n1-start): resolve current user via `getCurrentUser` operation, then assign via `assign` operation.

### If "After design":
Keep provisional `$ID`. Record `ticket_deferred: true` in `story-overview.md` frontmatter. The publish step will create the ticket before publishing the design doc.

### If "No ticket":
Keep provisional `$ID`. Record `ticket_deferred: false` (no tracker ticket will be created).

## Phase 4: Initialize Memory

Create `$MEMORY_DIR/story-overview.md`:

```markdown
---
ticket: <ID>
type: story
step: intake
repos:
<for each repo path, indented with "  - ">
phases_count: 0
tasks_count: 0
article_id: null
review_rounds: 0
ticket_deferred: <true|false>
---

# <ID>: <Title>

## Progress
- [x] Intake
- [ ] Analysis
- [ ] Discovery
- [ ] Design
- [ ] Review
- [ ] Publish
- [ ] Decompose

## Task Mapping
(populated during decompose step)
```

**Step result:** `outcome: "pass"`, `next_step: "analysis"`
