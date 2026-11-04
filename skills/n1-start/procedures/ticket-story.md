# Ticket step: Story children and Story handoff

Read from `steps/ticket.md` when `ISSUE_TYPE=story` or `IS_STORY=true`.

**Story children** (`ISSUE_TYPE=story` only): Jira: `mcp__<trackerMcp>__<operations.search>` JQL `parent = <ID>`, maxResults 1, `cloudId` when set. YouTrack: `operations.getIssueLinks`, any `subtask` link with `<ID>` as parent. Jira: non-empty `issues` list→`has`, parsed empty `issues` list→`none`. YouTrack: a parent `subtask` link→`has`, parsed links without one→`none`. Error, absent search/links op, missing `issues`, or unparseable→`unknown`. Never infer from `total` (jc-mcp's `/search/jql` omits it).
```bash
source ~/.n1/preamble.sh; source "$N1_ROOT/lib/queue.sh"
n1_story_convert_decision "$(n1_config_val '.tracker.type')" "<has|none|unknown>" "$(n1_config_val '.tracker.versionMcp')"
```
`story`→`IS_STORY=true`. `single:<r>`→token `unconverted: <r>`. `convert`→`mcp__<versionMcp>__jcm_convertIssueType` `issueKeys:[<ID>]`, `issueTypeName:"Task"`. `ok:true`→token `converted`, then `operations.addComment` "N1: converted Story to Task, it has no sub-tasks. Running it as a single ticket." (ignore failure). Anything else (error, `RUNNING`, declined)→token `convert-failed: <message, one line, ≤80 chars>`. Write the token to `$N1_HOME/memory/<ID>/.story-convert` via the file-write mechanism, never a shell string. Never prompt or retry. Single/convert outcomes continue as a single ticket; `ISSUE_TYPE` not story: skip this block.

`IS_STORY=true` (apply after the step file's `INVESTIGATION_DETECTED=true` check, which stops first): non-headless→handoff `n1:n1-queue --story <ID>` (end the step: `source ~/.n1/preamble.sh; n1_step_end "ticket" 1 skipped '{"skip_reason":"story_handoff"}'`), STOP; headless→`procedures/autonomy-headless.md § Headless Guard`.
