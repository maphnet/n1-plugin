# Procedure: Ticket Tagging

Applies to every tracker create call N1 makes: n1-ticket, n1-refine children, n1-start brain-dump creation and investigation follow-ups, n1-finish telemetry follow-ups, follow-up filing (`followup-filing.md` § File), and n1-run or ad hoc creation (`ticket-scope.md` § Create-call parameters). Creation only: an adopted ticket (n1-refine Adopt) or any existing ticket is never re-tagged or labeled.

## § Resolve

Run once before building the create call(s):

```bash
source ~/.n1/preamble.sh
TAGGING_ENABLED=$(n1_config_val '.ticketTagging.enabled')
TAGGING_SERVICE=$(n1_config_val '.ticketTagging.service')
TAGGING_LABEL=$(printf '%s' "$TAGGING_SERVICE" | tr '[:upper:]' '[:lower:]' | tr -s ' \t' '-' | tr -cd 'a-z0-9._-' | sed 's/^[-._]*//; s/[-._]*$//')
[ "$TAGGING_ENABLED" = true ] || TAGGING_LABEL=
printf 'TAGGING_ENABLED=%s\nTAGGING_SERVICE=%s\nTAGGING_LABEL=%s\nEDIT_OP=%s\n' "$TAGGING_ENABLED" "$TAGGING_SERVICE" "$TAGGING_LABEL" "$(n1_config_val '.tracker.operations.editTicket')"
```

Read every value from the output. Tagging is active only when `TAGGING_ENABLED` is `true` and `TAGGING_SERVICE` is non-empty. When active:

- `summary` = `<TAGGING_SERVICE> | <title>`; skip the prefix if the title already starts with `<TAGGING_SERVICE> |`.
- Prepend a `**Service:** <TAGGING_SERVICE>` line to the description.

Otherwise `summary` = title as-is, no `**Service:**` line, no label.

`TAGGING_LABEL` is the service lowercased, whitespace runs turned into `-`, every character outside `a-z0-9._-` dropped (non-ASCII letters included), leading and trailing `-`, `.`, `_` trimmed: Jira labels cannot contain spaces. An empty result means no label; the prefix and the `**Service:**` line still apply. Labels share the namespace n1-queue tag intake searches (`labels = "<tag>"`): a service named like a queue tag would make every N1-created ticket match it. Nothing refuses this collision today: choose a service name that differs from every queue tag.

## § Label after create

Run after the create call succeeds and the new key is known, before any assign, link or marker step. Skip when `TAGGING_LABEL` is empty.

- **Jira, create op (`tracker.operations.createIssue`) starts with `jcm_`** (jc-mcp; its create call has no labels parameter): if `EDIT_OP` is empty, emit `> Warning: Could not label <KEY> with <TAGGING_LABEL>: tracker.operations.editTicket is not configured` and continue. Otherwise call `mcp__<TRACKER_MCP>__<EDIT_OP>` with `issueKey: <KEY>` and `update: {"labels":[{"add":"<TAGGING_LABEL>"}]}`. Never pass labels under `fields`: `fields` replaces the whole label list, and `fields` plus `update` on the same field is rejected. A tool error or an `ok:false` response (for example a declined write confirmation) is a failure: emit `> Warning: Could not label <KEY> with <TAGGING_LABEL>: <error or message>` and continue. No retry, no rollback, never block; the label result never changes what later steps do (same as the assign step).
- **YouTrack:** no label operation. Emit `> Warning: Service label skipped: YouTrack has no label operation (prefix and **Service:** line still applied)` once per run, not per ticket, and continue.
- **Jira, any other create op, ticket created through `mcp__<VERSION_MCP>__jcm_createIssue`** (n1-refine children on a Rovo tracker with a jc-mcp version server): the ticket was created by jc-mcp, so label it with `mcp__<VERSION_MCP>__jcm_editIssue` using the same `issueKey` and `update` arguments and the same failure handling.
- **Jira, any other create op, created through the tracker's own op** (Atlassian Rovo `createJiraIssue`): no label; the prefix and the `**Service:**` line still apply.
