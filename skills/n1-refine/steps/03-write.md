<!-- Purpose: draft block, preview menu, write or comment, handoff (Steps 1-4). -->

## Step 1: Draft Block

Build the block from the Step 2-5 results of `02-loop.md`. Plain bullets for both trackers (Jira strips checkbox brackets; see `agents/product-analyst.md` § Jira formatting rule). An empty section holds `- None`.

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

Show the verdict line from `02-loop.md` Step 5, then the block, then ask the user.

1 — Write (Recommended): puts the block in the description, where `agents/product-analyst.md` § Idempotency detects it
2 — Edit: say what to change
3 — Cancel: write nothing

`EDIT_OP` empty: replace Write with "Comment: post the block as a comment" (no Recommended mark). `COMMENT_OP` also empty: print the block and say "No tracker write available; paste it yourself." **STOP.** Edit: apply the change, redraft, show this preview again. Cancel: say "Nothing written." **STOP.**

## Step 3: Write

**Write:** Re-fetch the ticket immediately before the write (`mcp__<TRACKER_MCP>__<READ_OP>`). If the description differs from `DESC_ORIG`, rebuild the new description from the fresh copy, set `DESC_ORIG` to the fresh description, show what changed, and return to Step 2; never overwrite blindly. Build the new description: if it has a line `*Refined by N1*` (match regardless of `*` or `_` emphasis, whole line), replace exactly the lines from it through the next `End of Refined by N1` line (same emphasis rule), inclusive, and nothing else. A block with no end line (written before the end line existed): replace from the marker through the last contiguous `- ` line directly under its `### Assumptions` heading, stopping at the first blank line or heading; text after that belongs to people. Otherwise append a blank line and the block. Show the full old and new description to the user as a diff before the call. Then make one `mcp__<TRACKER_MCP>__<EDIT_OP>` call carrying only the description (Jira: `cloudId`, `issueIdOrKey`, `description`; YouTrack: `issueId`, `description`) as structured tool arguments, never through a shell string. On failure: print the error and the block, and offer Comment.

**Comment:** one `mcp__<TRACKER_MCP>__<COMMENT_OP>` call with the block as the comment body. A comment is never edited in place; a later re-run posts a new one. Downstream reads only the newest of the last 5 comments whose first line equals the marker (whole line, `*` or `_` emphasis), so re-run refine if later comments push it out.

## Step 4: Handoff

Print, then end. When the ticket's resolved type is `investigation` (01-fetch Step 3; `--investigate` on a Task-typed ticket does not count), it is still investigation-typed, so print the `--type task` form of the Next line only, and add "Queue and headless runs would still run the investigation; retype the ticket first."

```
Refined <ID> (<description|comment>). <verdict line>
Next: /n1:n1-start <ID>            (investigation-typed ticket: /n1:n1-start <ID> --type task)
Or queue it: add it to a /n1:n1-queue batch (tag or story), then run --plan.
```
