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
- **Adopt keys** — existing ticket keys (`<KEY>-<n>`) that the user presents as work to bring under this story. Store them as `ADOPT_KEYS`, separate from the breakdown. A key cited only as background stays plain text.

Present the story seed to the user for confirmation: "Here's the story scope I captured — does this look right?" If the user corrects anything, revise and re-present.

## Step 2: Scope Routing

Read `<N1_ROOT>/references/ticket-scope.md` and classify the confirmed seed. `SCOPE_TYPE=Task`: perform its Task handoff now and end this flow. `SCOPE_TYPE=Story`: continue with Step 3. Unresolved scope: continue through analysis/discovery, then classify in Step 6 before approval. This rule applies in both automatic and interactive modes.

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
n1_assign_gap_warn
```
Relay any `Warning:` line printed above to the user once; it is not repeated for the story or its subtasks.

**Jira subtask linking guard:** If `TRACKER_TYPE` is `jira` and `VERSION_MCP` is empty or null:

**Autonomy gate:** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')` via Bash (source `lib/config.sh` first). If `MP` is `auto`: skip this prompt and auto-proceed without subtask linking. Write a Decision Ledger row to the relevant overview.md if one is available (or skip ledger if no overview exists yet):
`| n1-story | mechanical | C | [auto] | jc-mcp not configured — proceed without subtask linking? | Continue without linking | Cancel | mechanicalPrompts=auto | --- |`
If `MP` is `ask`: warn the user and wait for confirmation: "Subtask linking requires jc-mcp (`tracker.versionMcp`). Subtasks will be created as standalone tickets without a parent link. Configure jc-mcp via `/n1:n1-init` to enable linking. Continue anyway?" Soft gate — proceed if user accepts. This soft gate covers new subtasks only.

**Adopt filter** (skip if `ADOPT_KEYS` is empty):
- `TRACKER_TYPE` is not `jira`: clear `ADOPT_KEYS`. The keys stay as plain text in the seed.
- A key that does not match `^<PROJECT_KEY>-[0-9]+$`: tell the user "<KEY> is outside <PROJECT_KEY>; bulk move needs the same project" and drop it.
- `VERSION_MCP` is empty or null: warn "Adopting existing tickets requires jc-mcp (`tracker.versionMcp`); <keys> will not be adopted." and clear `ADOPT_KEYS`. Do not prompt, in either `mechanicalPrompts` mode, and never create new tickets for them.

**Duplicate check:** follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=create`, `TEXT` = story seed goal + known requirements (Step 1), and `SELF_ID` / `OVERVIEW` empty. Remove every `ADOPT_KEYS` entry from the search hits before classifying, as § Check does for `SELF_ID`, so an adopted key never triggers the prompt. **Stop** → cancel without creating anything. Keep the returned `DUP_LINKS` for Step 8. A hit that is in `ADOPT_KEYS` is the user's explicit adopt, not a duplicate: drop it from `DUP_LINKS`.

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

Using the enriched context (story seed + analysis + discovery answers), reclassify with `<N1_ROOT>/references/ticket-scope.md`. `SCOPE_TYPE=Task`: perform the Task handoff and end this flow. Resolve remaining unknowns before proceeding. For `SCOPE_TYPE=Story`, structure the story:

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

**Adopted children:** do not re-describe `ADOPT_KEYS` entries as subtasks. Step 3 has already run, so a key that the user names in a discovery answer as existing work is added to `ADOPT_KEYS` only after applying the same three Step 3 adopt-filter checks to it.
