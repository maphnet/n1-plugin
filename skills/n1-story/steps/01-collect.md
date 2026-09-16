<!-- Purpose: Context capture, sanity check, tracker gate, analysis, discovery, and design (Steps 1-6). -->

## Step 1: Context Capture

Two input sources — combine both when available:

1. **Argument** — the text passed after the command (brain dump). This is the primary intent signal.
2. **Conversation** — prior messages in this Claude Code session. Summarize relevant context that relates to the argument or, if no argument, identify the main actionable outcome.

**Empty context guard:** If there is no argument AND no meaningful prior conversation, ask: "Please describe the feature or initiative you'd like to create a story for." Wait for the response, then use it as the argument.

Combine into a story seed:
- **Goal** — high-level what and why (1-2 sentences)
- **Known requirements** — bullet list from conversation context
- **Rough task breakdown** — initial decomposition as understood so far

Present the story seed to the user for confirmation: "Here's the story scope I captured — does this look right?" If the user corrects anything, revise and re-present.

## Step 2: Sanity Check

Review the story seed. If it looks like a single atomic task with no meaningful subtask decomposition, suggest:

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-proceed with the story (continue with Step 3). Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-story | mechanical | C | [auto] | Single-task scope detected — use n1-ticket? | Proceed with story | Use n1-ticket instead | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: continue to the prompt below.

"This looks like a single task rather than a multi-part story. Would you like to use `/n1:n1-ticket` instead?"

Soft gate — if the user says no, proceed with a story.

## Step 3: Tracker Gate

```bash
TRACKER_MCP=$(n1_config_val '.tracker.mcp')
TRACKER_TYPE=$(n1_config_val '.tracker.type')
PROJECT_KEY=$(n1_config_val '.tracker.projectKey')
```

If `TRACKER_MCP` is empty or null, tell the user: "No tracker configured. Run `/n1:n1-init` to set up a tracker." **STOP.**

Read tracker operations:
```bash
CREATE_ISSUE_OP=$(n1_config_val '.tracker.operations.createIssue')
GET_USER_OP=$(n1_config_val '.tracker.operations.getCurrentUser')
ASSIGN_OP=$(n1_config_val '.tracker.operations.assign')
ASSIGN_TO_CREATOR=$(n1_config_val '.tracker.assignToCreator')
LINK_OP=$(n1_config_val '.tracker.operations.linkIssues')
VERSION_MCP=$(n1_config_val '.tracker.versionMcp')
EDIT_OP=$(n1_config_val '.tracker.operations.editTicket')
EST_ENABLED=$(n1_config_val '.estimation.writeToTracker')
```

**Jira subtask linking guard:** If `TRACKER_TYPE` is `jira` and `VERSION_MCP` is empty or null:

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-proceed without subtask linking. Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-story | mechanical | C | [auto] | jc-mcp not configured — proceed without subtask linking? | Continue without linking | Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: warn the user and wait for confirmation: "Subtask linking requires jc-mcp (`tracker.versionMcp`). Subtasks will be created as standalone tickets without a parent link. Configure jc-mcp via `/n1:n1-init` to enable linking. Continue anyway?" Soft gate — proceed if user accepts.

## Step 4: Analysis

Spawn the `solution-architect` agent for a deeper codebase analysis.

Resolve model:
```bash
IFS=$'\t' read -r MODEL EFFORT < <(n1_resolve_agent 'solution-architect' 'standard')
```

Pass both `MODEL` and `EFFORT` to the spawn.

Spawn with these instructions:
- Scope: the story goal, requirements, and rough breakdown from Step 1
- Deliverable: a structured analysis (under 800 words) covering:
  - Technical feasibility assessment
  - Affected components and integration points (with file:line references)
  - Risks with confidence tags: `confident` / `uncertain` / `unknown`
  - Dependencies between the rough subtasks
- Do NOT propose solutions — analyze the landscape and flag gaps

## Step 5: Discovery

Review the analysis from Step 4 for gaps. Check the confidence tags:

**If there are `uncertain` or `unknown` tags:**

Run a short interactive interview — one question at a time, multiple choice when possible. Focus on resolving the unknowns that affect subtask scoping.

Rules:
- Maximum 5 questions (prefer fewer)
- Early exit: if the user says "that's enough" or "let's proceed", stop immediately
- Multiple choice preferred, open-ended when the answer space is too broad

**If all tags are `confident`:** skip this step entirely and say "Analysis looks solid — no gaps to resolve. Moving to design."

## Step 6: Design

Using the enriched context (story seed + analysis + discovery answers), structure the story:

**Story level:**
- Title (imperative, concise)
- Description (2-3 paragraphs covering the overall goal, approach, and scope)

**Subtasks** — each gets:
- Title (imperative, concise)
- Description (1-2 paragraphs)
- Scope — which components/files are affected
- Acceptance criteria — checklist format (3-5 items per subtask)
- Size estimate — XS / S / M / L / XL

Order subtasks by dependency (independent tasks first, dependent tasks after their prerequisites).
