<!-- Purpose: draft block, show it with actions, write or comment, listed conversion, children, handoff (Steps 1-4). -->

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

## Step 2: Actions and Display

**Actions** come from `PROPOSED` and `CONVERT` as confirmed in `02-loop.md` Step 4: `A1 Convert <ID> to <CONVERT>` first, then one `C<n> <child type>: <summary>` per child with its description and acceptance criteria (child type per Step 3c). Drop the actions that cannot run and print each under the block with its reason: every child when `CREATE_ISSUE_OP` is empty ("no create op configured"); Jira children when `CREATE_ISSUE_OP` does not start with `jcm_` and `VERSION_MCP` is empty ("no parent link without jc-mcp"); YouTrack children when `LINK_OP` is empty ("no link op configured"). `A1` is never run: Step 3b lists it for the user.

Print the verdict line from `02-loop.md` Step 5, then the block, then the Actions list when it is non-empty, and go to Step 3 without asking; the `02-loop.md` Step 4 question already confirmed the Actions.

## Step 3: Write

`EDIT_OP` and `COMMENT_OP` both empty: print the block and the Actions and say "No tracker write available; paste it yourself." **STOP.** `EDIT_OP` empty: go to **Comment**.

**Write:** Re-fetch the ticket immediately before the write (`mcp__<TRACKER_MCP>__<READ_OP>`); never overwrite blindly. If the description differs from `DESC_ORIG`, set `DESC_ORIG` to the fresh description, print what changed, and re-fetch once more; if that second re-fetch differs again, write nothing, print the block and say "Description changed again; re-run /n1:n1-refine <ID>." **STOP.** Use the Step 1 block exactly, both marker lines included. Build the new description from the latest fetched description: if it has a line `*Refined by N1*` (match regardless of `*` or `_` emphasis, whole line), replace exactly the lines from it through the next `End of Refined by N1` line (same emphasis rule), inclusive, and nothing else. A block with no end line (written before the end line existed): replace from the marker through the last contiguous `- ` line directly under its `### Assumptions` heading, stopping at the first blank line or heading; text after that belongs to people. Otherwise append a blank line and the block. Print the full old and new description as a diff before the call; this is output, not a question. Then make one `mcp__<TRACKER_MCP>__<EDIT_OP>` call carrying only the description (Jira: `cloudId`, `issueIdOrKey`, `description`; YouTrack: `issueId`, `description`) as structured tool arguments, never through a shell string. On failure: print the error, then post the block with **Comment** without asking; with `COMMENT_OP` empty, print the block and the Actions and say "No tracker write available; paste it yourself." **STOP.**

**Comment:** one `mcp__<TRACKER_MCP>__<COMMENT_OP>` call with the Step 1 block as the comment body, passed as a structured tool argument. A comment is never edited in place; a later re-run posts a new one. Downstream reads only the newest of the last 5 comments whose first line equals the marker (whole line, `*` or `_` emphasis), so re-run refine if later comments push it out. On failure: print the error and the block. **STOP.**

**List mode** (`00-list.md`): after the Write or Comment call succeeds, append to `PRIOR` one entry: `<ID>:` followed by the block's Scope, Decisions and Assumptions lines. A failed write appends nothing.

**Actions:** only with a non-empty Actions list, and only after the Write or Comment call succeeded; a failed block write runs no Actions. Run Step 3b, then Step 3c, taking `A1` and every `C<n>` from the Step 2 list. Refine never changes the ticket's status and creates no branch.

## Step 3b: Conversion (listed, not run)

`A1` not listed: skip. Refine never converts a ticket's type: add `Convert <ID> to <CONVERT>: run it yourself` to the handoff's `Listed, not run` line. A held Jira `CONVERT=Story` also holds its Sub-tasks (Jira rejects Sub-tasks under a Task): skip Step 3c and add each child as `held Sub-task C<n>: <summary>` to the same line. A YouTrack conversion keeps its children (a `subtask of` link needs no parent type).

## Step 3c: Children

**Child type rule:** the child type follows the parent: Story under an Epic, Sub-task under a Story. Never `Task` under a Story: Jira rejects it (N1-294). YouTrack: create the child with the project's default type, then link it `subtask of` the parent. Scope and decomposition follow `references/ticket-scope.md` § Decomposition by ticket type.

For each listed `C<n>`, in order:

1. **Duplicate check:** run `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=create`, `TEXT=<child summary and description>`, `SELF_ID` empty, `OVERVIEW` empty; drop `<ID>` from its hits. Related hits are auto-linked as there. When § 4 would ask about remaining duplicate rows, ask the user instead, one question per child:

   No recommendation. The options are equivalent given the available evidence; select based on team preference.
   1 — Create anyway: create the child; with links offered, add `<HIT_ID>:Duplicate` to `DUP_LINKS`
   2 — Skip this child: create nothing for it. This is the § 4 Stop for refine; it never ends the run.

   Add each duplicate hit to the handoff's `Listed, not run` line as `adopt candidate <HIT_ID> for C<n>`; refine never moves an existing ticket.

2. **Create:** description = child description plus acceptance criteria as plain `- ` bullets (no checkbox brackets), passed as structured tool arguments, never through a shell string. `<PROJECT>` is the key prefix of `<ID>`. Tag `summary` and the description per `<N1_ROOT>/references/ticket-tagging.md` § Resolve.
   - Jira, `CREATE_ISSUE_OP` starts with `jcm_`: `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with `projectKey: <PROJECT>`, `issueType: <child type>`, `summary`, `description`, `parentKey: <ID>`.
   - Jira, other op: `mcp__<VERSION_MCP>__jcm_createIssue` with `projectKey: <PROJECT>`, `issueType: <child type>`, `summary`, `description`, `parentKey: <ID>` (no `cloudId`).
   - YouTrack: `mcp__<TRACKER_MCP>__<CREATE_ISSUE_OP>` with `project: <PROJECT>`, `summary`, `description`; then `mcp__<TRACKER_MCP>__<LINK_OP>` with source = the new child, target = `<ID>`, link type `subtask of`, using the tool's own argument names. Link failure: warn "Could not link <child> to <ID>: <error>" and continue.
   Jira create errors because the type name is unknown: take the name from the types the error lists that matches `sub-?task` or `story` (case-insensitive) and repeat the call once.
   After a successful create, apply `<N1_ROOT>/references/ticket-tagging.md` § Label after create with the new child ID. Then, when `DUP_LINKS` is non-empty, follow § Apply Links with `SOURCE_ID=<new child ID>`. A failed create prints the error and continues with the next child.

Add every key created here to `CHILDREN` (failed or skipped ones not), so Step 4 sees them next to the existing children.

## Step 4: Handoff

Print, then the Sub-task offer below when it applies, then end. When the ticket's resolved type is `investigation` (01-fetch Step 3; `--investigate` on a Task-typed ticket does not count), it is still investigation-typed, so print the `--type task` form of the Next line only, and add "Queue and headless runs would still run the investigation; retype the ticket first." Print the Actions line only when Step 3c ran, and the `Listed, not run` line only when it holds an item.

```
Refined <ID> (<description|comment>). <verdict line>
Actions: created <keys>; skipped <n>; failed <keys>
Listed, not run: <Convert <ID> to <type>: run it yourself; held Sub-task C<n>: <summary>; adopt candidate <HIT_ID> for C<n>>
Re-run /n1:n1-refine <ID> to change the block.
Next: /n1:n1-start <ID>            (investigation-typed ticket: /n1:n1-start <ID> --type task)
Or queue it: add it to a /n1:n1-queue batch (tag or story), then run --plan.
```

List mode (`00-list.md`): print only the `Refined` line and, when they apply, the `Actions` and `Listed, not run` lines; no Re-run, Next or queue line and no Sub-task offer (`00-list.md` Step 6 reports the Sub-task keys); then return to `00-list.md` Step 5.

**Sub-task offer:** after the handoff, when `ISSUE_TYPE` is `story` and `CHILDREN` holds at least one key, run the check below, then ask the user (format: `<N1_ROOT>/references/question-format.md`). No offer when `CHILDREN` is empty or `unknown`, or when the check prints `queue-run:yes` or `headless:yes` (queue and headless runs end here).

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
