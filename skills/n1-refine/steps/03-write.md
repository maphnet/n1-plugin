<!-- Purpose: draft block, preview with actions, write or comment, conversion, children, handoff (Steps 1-4). -->

List mode (`00-list.md`): a **STOP**, "end refine" or "refine ends here" in this file ends only the current ticket; `00-list.md` Step 5 records the outcome and goes on with the next ticket.

## Step 1: Draft Block

Build the block from the Step 2-5 results of `02-loop.md`. Plain bullets for both trackers (Jira strips checkbox brackets; see `agents/product-analyst.md` § Jira formatting rule). An empty section holds `- None`.
Never restate a contradicted or unverified ticket claim about current behavior as fact in Scope, Decisions or Acceptance Criteria; use the evidence-backed version, and record the claim as an Assumption per `02-loop.md` Step 1. Requirements for behavior not yet implemented stay in Acceptance Criteria; they are not claims. If the user chose to keep the ticket's direction (Continue), keep that direction as a Decision and record the contradicting evidence as an Assumption.

```
*Refined by N1*

### Scope
- In: <item>
- Out: <item>

### Decisions
- D<n> <topic>: <chosen>. Why: <reason>. Rejected: <alt>.

### Acceptance Criteria
- <criterion>

### Assumptions
- <X> (default). If wrong: <what changes>.

*End of Refined by N1*
```

The last line closes the block; text outside the two marker lines belongs to people and is never replaced. Acceptance Criteria: the ticket's criteria amended by the Decisions; this list is authoritative downstream.

## Step 2: Preview

**Actions** come from `PROPOSED` and `CONVERT` (`02-loop.md` Step 4): `A1 Convert <ID> to <CONVERT>` first, then one `C<n> <child type>: <summary>` per child with its description and acceptance criteria (child type per Step 3c). Drop the actions that cannot run and print each under the block with its reason: every child when `CREATE_ISSUE_OP` is empty ("no create op configured"); Jira children when `CREATE_ISSUE_OP` does not start with `jcm_` and `VERSION_MCP` is empty ("no parent link without jc-mcp"); YouTrack children when `LINK_OP` is empty ("no link op configured"); a Jira conversion when `VERSION_MCP` is empty ("conversion needs jc-mcp; convert <ID> manually"); a YouTrack conversion ("convert <ID> manually"; its children stay, a `subtask of` link needs no parent type). A dropped Jira `CONVERT=Story` also drops its Sub-tasks.

**Save the draft** before every showing of this preview (the first one, and every return from Edit, Remove or Step 3). First record the draft for the PreCompact hook; it prints the per-session draft directory `<DRAFT_DIR>` (a non-zero exit with no path only loses the compaction hint: use `$N1_HOME/memory/<ID>/refine/` as `<DRAFT_DIR>` and go on):

```bash
source ~/.n1/preamble.sh
n1_refine_draft_state write "<ID>" || echo "refine-draft: pointer not saved; continuing"
```

Then, with the file-write mechanism (`<N1_ROOT>/references/file-write-mechanism.md`), overwrite `<DRAFT_DIR>/block.md` (that is `$N1_HOME/memory/<ID>/refine/<session id>/block.md`) with the Step 1 block, both marker lines included, and `<DRAFT_DIR>/actions.md` with the Actions left after the drop rules: `A1 Convert <ID> to <CONVERT>` when listed, then each `C<n> <child type>: <summary>` with its description, acceptance criteria and links when it has any (`- None` when no action is left). The directory is per session, so another session refining the same ticket never overwrites these files.

Both files stay after the write. **Clear the draft pointer** when the preview is resolved (Cancel, the no-tracker-write STOP, Step 4); the files are kept:

```bash
source ~/.n1/preamble.sh
n1_refine_draft_state clear || true
```

Show the verdict line from `02-loop.md` Step 5, then the block exactly as saved in `block.md`, then the Actions list exactly as saved in `actions.md` when it is non-empty, then ask the user (format: `<N1_ROOT>/references/question-format.md`).

1 — Write (Recommended): puts the block in the description, where `agents/product-analyst.md` § Idempotency detects it, then runs every listed action (chosen by `references/ticket-scope.md` § Decomposition by ticket type)
2 — Edit: say what to change; works when the block or an action needs a change before writing
3 — Cancel: write nothing; works when the ticket should stay as it is for now
4 — Block only: write the block, run no action; works when the block is right but the actions should wait
5 — Remove: name an action (`A1` or `C<n>`) to drop; works when one listed action is wrong

Options 4 and 5 appear only with a non-empty Actions list. `EDIT_OP` empty: replace Write with "Comment: post the block as a comment, then run every listed action" (no Recommended mark). `COMMENT_OP` also empty: print the block and the Actions and say "No tracker write available; paste it yourself." Clear the draft pointer. **STOP.** Edit: apply the change (block or Actions), redraft, save the draft again, show this preview again. Remove: drop that action, save the draft again (so `actions.md` no longer lists it), show this preview again; dropping `A1` when `CONVERT=Story` also drops every Sub-task (Jira rejects Sub-tasks under a Task). Cancel: clear the draft pointer, say "Nothing written." **STOP.**

## Step 3: Write

**Write:** Re-fetch the ticket immediately before the write (`mcp__<TRACKER_MCP>__<READ_OP>`). If the description differs from `DESC_ORIG`, rebuild the new description from the fresh copy, set `DESC_ORIG` to the fresh description, show what changed, and return to Step 2; never overwrite blindly. Take the block from `<DRAFT_DIR>/block.md`, never from conversation text: read it with the file-read tool (never a shell `cat`), drop only the line-number prefix the tool adds to each line, and keep every other character and line break as it is. Build the new description: if it has a line `*Refined by N1*` (match regardless of `*` or `_` emphasis, whole line), replace exactly the lines from it through the next `End of Refined by N1` line (same emphasis rule), inclusive, and nothing else. A block with no end line (written before the end line existed): replace from the marker through the last contiguous `- ` line directly under its `### Assumptions` heading, stopping at the first blank line or heading; text after that belongs to people. Otherwise append a blank line and the block. Show the full old and new description to the user as a diff before the call. Then make one `mcp__<TRACKER_MCP>__<EDIT_OP>` call carrying only the description (Jira: `cloudId`, `issueIdOrKey`, `description`; YouTrack: `issueId`, `description`) as structured tool arguments, never through a shell string. On failure: print the error and the block, and offer Comment.

**Comment:** one `mcp__<TRACKER_MCP>__<COMMENT_OP>` call with the block from `block.md` (read as in Write) as the comment body. A comment is never edited in place; a later re-run posts a new one. Downstream reads only the newest of the last 5 comments whose first line equals the marker (whole line, `*` or `_` emphasis), so re-run refine if later comments push it out.

**List mode** (`00-list.md`): after the Write or Comment call succeeds, append to `PRIOR` one entry: `<ID>:` followed by the block's Scope, Decisions and Assumptions lines. A failed write appends nothing.

**Actions:** only when the user picked Write (or Comment) with a non-empty Actions list, and only after that call succeeded; a failed block write runs no Actions. Run Step 3b, then Step 3c, taking `A1` and every `C<n>` from `<DRAFT_DIR>/actions.md` (read as in Write), never from conversation text. Refine never changes the ticket's status and creates no branch.

## Step 3b: Conversion

`A1` not listed: skip. Jira: call `mcp__<VERSION_MCP>__jcm_convertIssueType` with `issueKeys: [<ID>]`, `issueTypeName: <CONVERT>` (`Task` or `Story`), as `skills/n1-start/procedures/ticket-story.md` does for Story to Task. `ok: true`: report "Converted <ID> to <CONVERT>". Anything else (an error, `RUNNING`, declined): print the error or message, keep the block, and when `CONVERT=Story` skip Step 3c (Jira rejects Sub-tasks under a Task).

## Step 3c: Children

**Child type rule:** the child type follows the parent: Story under an Epic, Sub-task under a Story (including a Task just converted to Story). Never `Task` under a Story: Jira rejects it (N1-294). YouTrack: create the child with the project's default type, then link it `subtask of` the parent.

For each listed `C<n>`, in order:

1. **Duplicate check:** run `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=create`, `TEXT=<child summary and description>`, `SELF_ID` empty, `OVERVIEW` empty; drop `<ID>` from its hits. Related hits are auto-linked as there. When § 4 would ask about remaining duplicate rows, ask the user instead, one question per child:

   No recommendation. The options are equivalent given the available evidence; select based on team preference.
   1 — Adopt <HIT_ID>: convert that ticket into this child under <ID> (one option per duplicate hit; offered only on Jira with `VERSION_MCP` non-empty)
   2 — Create anyway: create the child; with links offered, add `<HIT_ID>:Duplicate` to `DUP_LINKS`
   3 — Skip this child: create nothing for it. This is the § 4 Stop for refine; it never ends the run.

2. **Adopt:** call `mcp__<VERSION_MCP>__jcm_convertIssueType` with `issueKeys: [<HIT_ID>]`, `issueTypeName: <child type>`, `parentKey: <ID>`. If it errors because the type name is unknown, take the name from the types the error lists that matches `sub-?task` (Sub-task child) or `story` (Story child), case-insensitive, and repeat the call once. `ok: true`: report "Adopted <HIT_ID> as <issueType> under <ID>". `ok: false` with `status` `RUNNING`, `ENQUEUED` or `CANCEL_REQUESTED`: "Move still <status>; confirm later with `jcm_getIssue <HIT_ID>`" (pending, not adopted). `ok: false` with `message` and no `status`: "Adoption declined; <HIT_ID> not moved under <ID>." Anything else: "Could not adopt <HIT_ID>: <error or message>. Convert it manually or upgrade jc-mcp (0.9.0 or newer)." Never create a ticket for a key that failed to adopt; an adopted child applies no links.

3. **Create:** description = child description plus acceptance criteria as plain `- ` bullets (no checkbox brackets), passed as structured tool arguments, never through a shell string. `<PROJECT>` is the key prefix of `<ID>`.
   - Jira, `CREATE_ISSUE_OP` starts with `jcm_`: `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with `projectKey: <PROJECT>`, `issueType: <child type>`, `summary`, `description`, `parentKey: <ID>`.
   - Jira, other op: `mcp__<VERSION_MCP>__jcm_createIssue` with `projectKey: <PROJECT>`, `issueType: <child type>`, `summary`, `description`, `parentKey: <ID>` (no `cloudId`).
   - YouTrack: `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with `project: <PROJECT>`, `summary`, `description`; then `mcp__<TRACKER_MCP>__<LINK_OP>` with source = the new child, target = `<ID>`, link type `subtask of`, using the tool's own argument names. Link failure: warn "Could not link <child> to <ID>: <error>" and continue.
   Jira create errors because the type name is unknown: take the name from the types the error lists that matches `sub-?task` or `story` (case-insensitive) and repeat the call once, as in Adopt.
   Then, when `DUP_LINKS` is non-empty, follow § Apply Links with `SOURCE_ID=<new child ID>`. A failed create prints the error and continues with the next child.

Add every key created or adopted here to `CHILDREN` (adopted and pending keys included, failed or skipped ones not), so Step 4 sees them next to the existing children.

## Step 4: Handoff

First clear the draft pointer (Step 2). Print, then the Sub-task offer below when it applies, then end. When the ticket's resolved type is `investigation` (01-fetch Step 3; `--investigate` on a Task-typed ticket does not count), it is still investigation-typed, so print the `--type task` form of the Next line only, and add "Queue and headless runs would still run the investigation; retype the ticket first." Print the Actions line only when Step 3b or 3c ran.

```
Refined <ID> (<description|comment>). <verdict line>
Actions: converted <ID> to <type>; created <keys>; adopted <keys>; skipped <n>; failed <keys>
Next: /n1:n1-start <ID>            (investigation-typed ticket: /n1:n1-start <ID> --type task)
Or queue it: add it to a /n1:n1-queue batch (tag or story), then run --plan.
```

List mode (`00-list.md`): print only the `Refined` line and, when Step 3b or 3c ran, the `Actions` line; no Next or queue line and no Sub-task offer (`00-list.md` Step 6 reports the Sub-task keys); then return to `00-list.md` Step 5.

**Sub-task offer:** after the handoff, when `ISSUE_TYPE` is `story`, or Step 3b converted the ticket to Story, and `CHILDREN` holds at least one key, run the check below, then ask the user (format: `<N1_ROOT>/references/question-format.md`). No offer when `CHILDREN` is empty or `unknown`, or when the check prints `queue-run:yes` or `headless:yes` (queue and headless runs end here).

```bash
source ~/.n1/preamble.sh
[ -z "${N1_QUEUE_RUN_ID:-}" ] || echo queue-run:yes; [ "${N1_HEADLESS:-}" != 1 ] || echo headless:yes
```

No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Refine Sub-tasks: invoke skill n1-refine once per key in `OFFER_KEYS`; works when the children are not yet refined
2 — Done: end the run with the handoff above; works when the children should be refined later

Option 1: first copy `CHILDREN` into a separate held list `OFFER_KEYS` (each nested run resets `CHILDREN`), then iterate `OFFER_KEYS` only, one key per invocation. Before each next child ask the user:

```
Next: <KEY> <summary>. Continue?
No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Refine <KEY>: works when you want to go on
2 — Stop: works when the remaining children should wait
```

Option 2 and Stop: end the run.
