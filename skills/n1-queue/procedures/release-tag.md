# Procedure: Release Queue Tag

Removes the queue tag from one ticket after the queue hands it off (PR, escalation, failure) and records the result in the ticket's memory, so the next intake can tell a stale tag from an explicit re-queue. **Best-effort:** any failure here is reported but never blocks the caller.

**Inputs:** `ID` (ticket key), `TAG` (tag/label to remove), `OVERVIEW` (absolute path of the ticket's `overview.md`).
**Output:** print `TAG_RELEASE=<outcome>`, one of `removed`, `absent`, `failed:<error>`, `skipped:<reason>`.

1. If `TAG` is empty: outcome `skipped:no-tag`; stop.
2. Resolve tracker operations:
   ```bash
   source ~/.n1/preamble.sh
   printf 'TRACKER_MCP=%s\nTRACKER_TYPE=%s\nREAD_OP=%s\nEDIT_OP=%s\nCLOUD_ID=%s\n' \
     "$(n1_config_val '.tracker.mcp')" "$(n1_config_val '.tracker.type')" \
     "$(n1_config_val '.tracker.operations.readTicket')" "$(n1_config_val '.tracker.operations.editTicket')" \
     "$(n1_config_val '.tracker.cloudId')"
   ```
   Read the values from the output above. `TRACKER_MCP` empty: outcome `skipped:no-tracker`; stop. `EDIT_OP` empty: print `tag removal unavailable: editTicket not configured — re-run /n1:n1-init tracker step`, outcome `skipped:no-editTicket`; stop.
3. Read the ticket via `mcp__<TRACKER_MCP>__<READ_OP>` (Jira: include `cloudId`). If `TAG` is not among its tags (YouTrack) or `labels` (Jira): outcome `absent`; go to step 5.
4. Remove the tag via `mcp__<TRACKER_MCP>__<EDIT_OP>`:
   - **YouTrack:** pass the issue ID and `remove_tag: "<TAG>"`. If the read in step 3 did not expose tags, call this directly and treat a "tag not found"-style error as `absent`.
   - **Jira:** include `cloudId` and the issue key. If the tool schema accepts an `update` object, send `update: {"labels": [{"remove": "<TAG>"}]}` (atomic). Otherwise send `fields: {"labels": <labels from step 3 without TAG>}` (read-modify-write; replaces the whole array).
   Outcome `removed` on success, `failed:<error>` on any tool error. Do not retry.
5. Only for `removed` or `absent`, record the release:
   ```bash
   source ~/.n1/preamble.sh
   n1_write_frontmatter "$OVERVIEW" queue_tag_removed true || true
   ```
   Never write `true` for `failed:*` or `skipped:*` — the queue's intake keeps excluding the ticket until a release is confirmed.
6. Print `TAG_RELEASE=<outcome>` and return to the caller.
