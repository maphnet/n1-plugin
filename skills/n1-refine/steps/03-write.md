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
```

Acceptance Criteria: the ticket's criteria amended by the Decisions; this list is authoritative downstream.

## Step 2: Preview

Show the verdict line from `02-loop.md` Step 5, then the block, then ask the user.

`WRITE_MODE=description`:
1 — Write (Recommended): puts the block in the description, where `agents/product-analyst.md` § Idempotency detects it
2 — Edit: say what to change
3 — Comment: post the block as a comment instead
4 — Cancel: write nothing

`WRITE_MODE=comment`: first say "<reporter> reported this ticket, not you (or the author could not be checked)."
1 — Comment (Recommended): leaves another person's description untouched (`01-fetch.md` Step 2 author check)
2 — Write: replace the block in the description anyway
3 — Edit: say what to change
4 — Cancel: write nothing

Drop Write when `EDIT_OP` is empty and Comment when `COMMENT_OP` is empty. Both empty: print the block and say "No tracker write available; paste it yourself." **STOP.** Edit: apply the change, redraft, show this preview again. Cancel: say "Nothing written." **STOP.**

## Step 3: Write

**Write:** Re-fetch the ticket immediately before the write (`mcp__<TRACKER_MCP>__<READ_OP>`). If the description differs from `DESC_ORIG`, rebuild the new description from the fresh copy, show what changed, and return to Step 2; never overwrite blindly. Build the new description: if it has a line that is exactly `*Refined by N1*`, replace from that line up to (not including) the next line that starts with `*` and contains `N1`, or to the end; otherwise append a blank line and the block. Then make one `mcp__<TRACKER_MCP>__<EDIT_OP>` call carrying only the description (Jira: `cloudId`, `issueIdOrKey`, `description`; YouTrack: `issueId`, `description`) as structured tool arguments, never through a shell string. On failure: print the error and the block, and offer Comment.

**Comment:** one `mcp__<TRACKER_MCP>__<COMMENT_OP>` call with the block as the comment body. A comment is never edited in place; a later re-run posts a new one. Downstream reads only the newest of the last 5 comments that starts with the marker, so re-run refine if later comments push it out.

## Step 4: Handoff

Print, then end:

```
Refined <ID> (<description|comment>). <verdict line>
Next: /n1:n1-start <ID>
Or queue it: add it to a /n1:n1-queue batch (tag or story), then run --plan.
```
