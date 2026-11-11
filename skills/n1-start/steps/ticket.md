> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

**Spawn product-analyst.** Detect mode and params. Ticket: `mode=ticket ticketId trackerMcp operations trackerType ticketMdPath`; add error fields if `ET_CONFIGURED`. File: `mode=file filePath ticketMdPath`. Brain dump: `mode=text content ticketMdPath`. Error tracker: `mode=error-tracker issueId issueUrl`+error fields; provisional `<ID>=sentry-<issueId>`. Always: `enrichmentEnabled` (`ticketEnrichment.enabled != false`), `cloudId` (Jira only).

Write the product-analyst's full returned text to `$N1_HOME/memory/$ID/ticket-return.md` with the file-write mechanism (never paste it into a shell command or string), then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/ticket-step.sh"
n1_step_begin "ticket" 1
n1_ticket_intake '<TYPE_OVERRIDE from input parsing, empty if none>'
```
Output: `TITLE=`, `CLOUD_ID=`, `LINKED_ERROR_URL=` (non-empty: linked error; the type is already `bug`), `RESOLVED_TYPE=`, `TYPE_MATCHED_BY=`, `INVESTIGATION_DETECTED=`, `ISSUE_TYPE=`, `IS_STORY=`, `ORIGINAL_STATUS=`, `QUEUE_RUN_ID=`, `HEADLESS=`, and a `Hint:` line (relay it) when the title looks like an investigation. No `intake-result:` line: the call uses `{"title":null,"tags":[],"type":"task"}`.
**Brief:** only when QUEUE_RUN_ID is empty and HEADLESS is not 1, print the `brief:` line text from the analyst return (already in context) verbatim; print nothing in queue children, headless runs or without a `brief:` line; continue without pausing.

**Story/epic** (`ISSUE_TYPE=story` or `IS_STORY=true`): read `procedures/ticket-story.md` and follow it (Story children, convert decision, Story handoff); otherwise skip it.

`INVESTIGATION_DETECTED=true` with `N1_QUEUE_RUN_ID` unset and `N1_HEADLESS=1` not set: say "Interactive investigation moved: run `/n1:n1-refine <ID> --investigate`." (no tracker ID: `/n1:n1-ticket` first) and STOP before overview.md (run `source ~/.n1/preamble.sh; n1_step_end "ticket" 1 skipped '{"skip_reason":"investigation_moved"}'` first).

**ID-Final:** no memory file/branch until `<ID>` final. product-analyst writes ticket.md directly to `ticketMdPath`.

**Tracker ticket creation** (brain-dump/file/error-tracker+`createIssue`): Create without a prompt + ledger. →`createIssue` (summary/description per `<N1_ROOT>/references/ticket-tagging.md` § Resolve, then § Label after create), final `<ID>`, **Reconcile Memory ID & Branch**, assign, record URL. Type: `<N1_ROOT>/references/ticket-scope.md` § Free-form creation.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/ticket-step.sh"
n1_ticket_persist '<TYPE_OVERRIDE from input parsing, empty if none>'
```
Output: `TIER=` (`tier:` from the return, default `standard`), `SESSION_NAME=`, `ASSIGN_TO_CREATOR=`, `GET_USER_OP=`, `ASSIGN_OP=`, `READ_OP=` (used by **Assign to creator** below) and any `Warning:` line (missing assign ops; relay it). The call checks ticket.md, writes the return's signals and the overview.md frontmatter, and persists the ticket context. Missing/empty return: compact fallback. Run `/rename <printed SESSION_NAME>`. **Create overview.md**: frontmatter (ticket, tier, step, fix_cycles), heading, `## Context` (pending), `## Progress`, `## Key Decisions`, `## Escalations`. `INVESTIGATION_DETECTED=true`: investigation variant.

**Ticket URL** (mode=ticket): call `mcp__<trackerMcp>__get_instance_url` (format=json) → extract `base_url`. YouTrack: `TICKET_URL=<base_url>/issue/<ID>`. Jira: `TICKET_URL=<base_url>/browse/<ID>`. On failure: skip silently. `n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "ticket_url" "$TICKET_URL"`.

**Duplicate check:** follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=start`, `TEXT` = title + description from ticket.md, `SELF_ID=<ID>`, `OVERVIEW=$N1_HOME/memory/<ID>/overview.md` (cached; skipped on resume and in queue children — resolved at plan time). **Stop** → end as above (`duplicate`), then end the run as the procedure says.

**Blocker check** (mode=ticket only, an existing tracker ticket; after the duplicate check, before **Tracker status**): skip in a queue child. Read both with `printf 'QUEUE_RUN_ID=%s\nHEADLESS=%s\n' "${N1_QUEUE_RUN_ID:-}" "${N1_HEADLESS:-}"` after `source ~/.n1/preamble.sh`; the skip needs `N1_QUEUE_RUN_ID` set AND `N1_HEADLESS=1`, both (SEC-L2). Else follow `<N1_ROOT>/references/blocker-check.md` § Check with `ID=<ID>`, `CALLER=start`, then its § Report. **Stop** → end as above (`blocked`), then end the run; status untouched.

**Tracker status** (mandatory, before any analysis dispatch; interactive runs and queue children alike): `moveStatus` → In Progress (skip if absent; warn and continue).

`tracker.operations.addToSprint` (`n1_config_val`; only here; skip silently if empty): call with `<ID>` on `tracker.versionMcp` else `tracker.mcp`. `ok:true` → one overview.md `## Progress` line (`skipped` → say skipped); `ok:false` or tool error → warning line there (`reason`/`message`). Never prompt; non-fatal.

**Assign to creator** (if configured; never steal from an existing assignee): skip if ANY of `ASSIGN_TO_CREATOR` is `false`, `GET_USER_OP` empty, `ASSIGN_OP` empty, or (when `READ_OP` set) `READ_OP` on `<ID>` shows a non-empty assignee. Else call `GET_USER_OP` then `ASSIGN_OP` (payload per `n1-ticket/steps/02-create.md` Step 8). Failure: log to overview.md `## Progress`, continue — non-fatal. Use the four values `n1_ticket_persist` printed.

**Workspace** (`INVESTIGATION_DETECTED=false`; after Assign, so overview.md exists for a handoff or escalation): `procedures/workspace-isolation.md § Workspace Decision` with `FRESH=1`. A successful handoff or Stop closes the ticket step itself and STOPs the run: skip the block below.

**Close the step** (only when the run continues):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/ticket-step.sh"
n1_ticket_envelope
n1_step_end "ticket" 1 success
```
