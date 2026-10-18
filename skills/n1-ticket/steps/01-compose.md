<!-- Purpose: Context capture, sanity check, tracker gate, light analysis, light discovery (Steps 1-5). -->

## Step 1: Context Capture

Two input sources — combine both when available:

1. **Argument** — the text passed after the command (brain dump). This is the primary intent signal.
2. **Conversation** — prior messages in this Claude Code session. Summarize relevant context from the conversation that relates to the argument or, if no argument, identify the main actionable outcome.

**Empty context guard:** If there is no argument AND no meaningful prior conversation (e.g., this is the first message in the session), ask: "Please describe what you'd like to create a ticket for." Wait for the response, then use it as the argument.

Combine into a structured summary:
- **Title** — imperative mood, concise (under 80 chars)
- **Type** — `Task` or `Bug`. Auto-detect from context: bug indicators are broken behavior, regressions, errors, exceptions, crash reports. Default to `Task` when ambiguous.
- **Description** — 2-3 paragraphs covering what, why, and how
- **Acceptance criteria** — bulleted checklist (3-7 items)

Present the summary to the user for confirmation: "Here's what I captured — does this look right?" If the user corrects anything, revise and re-present.

## Step 2: Scope Routing

Read `<N1_ROOT>/references/ticket-scope.md` and classify the confirmed summary. `SCOPE_TYPE=Story`: perform its Story handoff now and end this flow. `SCOPE_TYPE=Task`: continue with Step 3, retaining Bug detection for defect reports. Unresolved scope: continue through analysis/discovery, then reclassify before creation approval. This rule applies in both automatic and interactive modes.

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
n1_assign_gap_warn
```
Relay any `Warning:` line printed above to the user once; the warning is not repeated at creation.

## Step 4: Light Analysis

Spawn the `solution-architect` agent for a quick codebase pass focused on the ticket scope.

Resolve model:
```bash
IFS=$'\t' read -r MODEL EFFORT < <(n1_resolve_agent 'solution-architect' 'light')
```

Pass both `MODEL` and `EFFORT` to the spawn.

Spawn with these instructions:
- Scope: the ticket title and description from Step 1
- Deliverable: a short analysis (under 300 words) covering:
  - Relevant components and files (with file:line references)
  - Basic feasibility assessment (straightforward / needs investigation / risky)
  - Key integration points
- Do NOT propose solutions — just map the landscape

Fold the analysis findings into the ticket description as a "Technical Context" section.

## Step 5: Light Discovery + Web Research

**Skip condition:** If the task is purely internal/codebase-specific (refactoring, renaming, config changes, fixing typos, internal tooling), skip this step entirely.

For tasks where external best practices add value (new features, architecture decisions, security patterns, API design):

Run 1-2 targeted web searches using WebSearch for:
- Current best practices relevant to the task
- Recent approaches or patterns in the ecosystem

Fold relevant findings into the description as brief enrichment (1-2 sentences each). Do not bloat the description — only include findings that inform implementation.
