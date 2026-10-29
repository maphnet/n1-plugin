<!-- Purpose: tracker gate, fetch, codebase analysis, optional investigation (Steps 1-5). -->

## Step 1: Tracker Gate

```bash
source ~/.n1/preamble.sh
TRACKER_MCP=$(n1_config_val '.tracker.mcp')
TRACKER_TYPE=$(n1_config_val '.tracker.type')
CLOUD_ID=$(n1_config_val '.tracker.cloudId')
READ_OP=$(n1_config_val '.tracker.operations.readTicket')
EDIT_OP=$(n1_config_val '.tracker.operations.editTicket')
COMMENT_OP=$(n1_config_val '.tracker.operations.addComment')
mkdir -p "$N1_HOME/memory/<ID>/refine"
echo "mcp=$TRACKER_MCP type=$TRACKER_TYPE cloud=$CLOUD_ID read=$READ_OP edit=$EDIT_OP comment=$COMMENT_OP"
```

`TRACKER_MCP` or `READ_OP` empty: say "No tracker configured. Run `/n1:n1-init` to set up a tracker." **STOP.** Keep the printed values for later steps.

## Step 2: Read Ticket

Call `mcp__<TRACKER_MCP>__<READ_OP>` (Jira: `cloudId`, `issueIdOrKey`; YouTrack: `issueId`). Keep the raw description as `DESC_ORIG` (`03-write.md` Step 3 compares against it). If `DESC_ORIG` already contains a `*Refined by N1*` line (match regardless of `*` or `_` emphasis, whole line), or after Step 3 refine/ticket.md carries `### Decisions` (a comment-mode block), this is a re-run: the most recent refined block (`agents/product-analyst.md` Refined block rule; a newer comment block supersedes the description block) is the starting draft.

Hold `DESC_ORIG` in this session; write no file for it.

## Step 3: Fetch

Dispatch persona `product-analyst` with `mode=ticket`, `ticketId=<ID>`, `trackerMcp`, `operations`, `trackerType`, `cloudId` (Jira only), `ticketMdPath=$N1_HOME/memory/<ID>/refine/ticket.md`, `enrichmentEnabled=false`, and the directive "Fetch only: make no tracker writes (no Title & Form Repair, no enrichment)." Wait for the persona to return.

```bash
source ~/.n1/preamble.sh
n1_verify_dependencies "$N1_HOME/memory/<ID>/refine" ticket.md || exit 1
INTAKE_RESULT=$(echo "$AGENT_OUTPUT" | grep -m1 '^intake-result: ' | sed 's/^intake-result: //')
TITLE=$(echo "$AGENT_OUTPUT" | grep -m1 '^title: ' | sed 's/^title: //')
TAGS_CSV=$(echo "$INTAKE_RESULT" | sed 's/.*"tags":\[//;s/\].*//' | tr -d '"' | tr -d ' ')
TYPE_FIELD=$(echo "$INTAKE_RESULT" | sed 's/.*[,{] *"type": *"\([^"]*\)".*/\1/')
n1_resolve_type "$TITLE" "$TAGS_CSV" "$TYPE_FIELD" "" 2>/dev/null
```

Printed type `investigation`: set `INVESTIGATE=true`.

## Step 4: Codebase Analysis

```bash
source ~/.n1/preamble.sh
IFS=$'\t' read -r SA_MODEL SA_EFFORT < <(n1_resolve_agent solution-architect analysis)
echo "$SA_MODEL $SA_EFFORT"
```

Dispatch persona `solution-architect` with that model and effort. Inputs: path `$N1_HOME/memory/<ID>/refine/ticket.md` (read it yourself). Output: write `$N1_HOME/memory/<ID>/refine/analysis.md` in your normal Output Format, including `### Ticket Validation` and the `ticket_contradictions` signal. Directive: "Append a `### Decision Points` section: every choice the ticket leaves open (scope edge, behavior, contract, acceptance gap). Per point: the question, 2-3 options, codebase evidence (file:line) for each, the recommended option when the evidence differentiates, and a tier: A (a wrong guess changes the design and the code cannot answer it), B (the code supports a defensible default), C (convention). Lines under ticket.md `### Decisions` are resolved; list one only if the code contradicts it." Wait for the persona to return.

```bash
source ~/.n1/preamble.sh
n1_verify_dependencies "$N1_HOME/memory/<ID>/refine" analysis.md || exit 1
```

## Step 5: Investigation (`INVESTIGATE=true` only)

Read `<N1_ROOT>/skills/n1-start/steps/investigation-deliverable.md` and follow it in its **Caller mode — n1-refine** (Phases 1-2, paths under `refine/`).

```bash
source ~/.n1/preamble.sh
n1_verify_dependencies "$N1_HOME/memory/<ID>/refine" investigation.md || exit 1
n1_read_signal "$N1_HOME/memory/<ID>/refine/investigation.md" implementable
```

Not `true`: show the `### Summary` and `### Recommendations` of investigation.md and say "Nothing implementable to refine; refine ends here and writes nothing to the ticket. Use `/n1:n1-ticket` for follow-up work." **STOP.** `true`: continue; its findings and unknowns feed `02-loop.md`.
