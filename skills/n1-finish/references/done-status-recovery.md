# Done-Status Runtime Recovery

When hard-skip gates pass but `tracker.statuses.done` is absent from config:

1. **Detect available statuses:**
   - Jira: call `mcp__<tracker.mcp>__<operations.getTransitions>` on the current ticket; extract the target status name from each transition.
   - YouTrack: call `mcp__<tracker.mcp>__<operations.readTicket>` on the current ticket; inspect `customFields` for the State field — read its bundle values (or `value.name` when a single value is present). Fallback: call `mcp__<tracker.mcp>__<operations.search>` for one sample issue in the project and read its State field.
   - **If detection fails** (MCP error or empty result): skip ticket closing. Message: "Ticket close skipped: `tracker.statuses.done` not configured and status detection failed. Re-run `/n1:n1-init` to configure it." Go to Step 5.

2. **Sort and auto-match:** names matching any of ("Done", "Closed", "Resolved", "Fixed", "Complete", "Completed") — case-insensitive substring — sort first.

3. **Mechanical-prompt auto-pick (standalone and step mode):** Read `MP=$(n1_autonomy_val 'mechanicalPrompts')`. If `MP` is `auto` AND exactly one status matches the auto-match list: patch config (same `jq` command as below) and append a Decision Ledger row to overview.md:

   `| finish | mechanical | B | [auto] | Exactly one done-status candidate: <status-name> | Auto-select and save to config | Prompt user | mechanicalPrompts=auto; unambiguous match |`

   Then continue to Move Status (skip steps 4 and 5 for this prompt). If `MP` is `auto` but zero or two or more candidates match: fall through to the prompt below (ambiguity requires human input even in auto mode).

4. **Standalone mode — interactive prompt:**
   ```
   tracker.statuses.done is not configured.

   Available statuses (best match first):
   1 — Done  ← auto-matched
   2 — Closed
   3 — Resolved
   0 — Skip ticket closing this time

   Which status should N1 use to close this ticket? (Selection saves to config.)
   ```
   - **Numbered pick** → patch `$N1_HOME/config.json` and hold the value in memory for the rest of this step:
     ```bash
     CONFIG="$N1_HOME/config.json"
     DONE_STATUS="<selected name>"
     TMP="$(jq --arg v "$DONE_STATUS" '.tracker.statuses.done = $v' "$CONFIG")"
     printf '%s\n' "$TMP" > "$CONFIG"
     ```
     If `jq` is unavailable, skip ticket closing with message: "Ticket close skipped: jq not available to patch config. Install jq and re-run." Go to Step 5.
   - **Pick 0** → skip ticket closing this run; nothing written to config. Go to Step 5.

5. **Step mode — escalation:** write `$N1_HOME/memory/<ID>/escalation/request.json`. The `options` array is built dynamically from the detected status names (best matches first, plain names) with `"Skip ticket closing this time"` appended as the last entry. The `recommendation` is the first best-match name, or `"Skip ticket closing this time"` if no match exists.
   ```json
   {
     "run_id": "<N1_RUN_ID>",
     "step": "finish",
     "questions": [{
       "id": "done_status_missing",
       "text": "tracker.statuses.done is not configured. Which status represents a closed/resolved ticket?",
       "options": ["<best-match-1>", "<best-match-2>", "...", "Skip ticket closing this time"],
       "recommendation": "<first best-match or Skip ticket closing this time>",
       "context": "Available statuses fetched from tracker. Selection will be saved to config."
     }]
   }
   ```
   Emit `outcome: "escalation"` and STOP.

   On re-run with `response.json` present and `run_id` matching `N1_RUN_ID`:
   - Response is a status name → patch config (same `jq` command above), set the value in memory, re-enter ticket close (continue to Move Status below).
   - Response is `"Skip ticket closing this time"` → append `Ticket: close skipped (user skipped at runtime)` to the `## Finish` section in overview.md; emit `outcome: "pass"`; go to Step 5.
