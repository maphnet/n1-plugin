# Tracker Escalation Procedures

Post-to-Tracker and Resume-from-Tracker procedures for the escalation channel.
All tracker calls use the `mcp__<tracker.mcp>__<operation>` form from TRACKER ROUTING context.

---

## Post-to-Tracker Procedure

**Inputs:** `{ID}`, `{step}`, `{questions}` array (same shape as `request.json`), `{N1_RUN_ID}`

**Gate:** only run when `n1_escalation_val channel` is `tracker` or `both`.

1. **Read current status.** Call `mcp__<tracker.mcp>__<operations.readTicket>` for `{ID}`. Record the current status name as `previous_status`.

2. **Attempt blocked-status transition.** Read `tracker.statuses.blocked` from config.
   - If configured: get transitions via `mcp__<tracker.mcp>__<operations.getTransitions>`, find a transition whose target name matches `tracker.statuses.blocked`. If found, call `mcp__<tracker.mcp>__<operations.moveStatus>` to move the ticket. Set `moved_to_blocked: true`.
   - If not configured, or no matching transition reachable: degrade to comment-only. Set `moved_to_blocked: false`. Never hard-fail — the comment is still posted.
   - See `references/blocked-status-recovery.md` for auto-match logic when `tracker.statuses.blocked` is absent.

3. **Resolve mention identity.**
   - If `escalation.mentionTarget` is set in config: use that value directly as the mention string.
   - Otherwise: call `mcp__<tracker.mcp>__<operations.getCurrentUser>`. Extract the user mention handle appropriate for the tracker type (Jira: accountId formatted as `[~accountId:...]`; YouTrack: `@username`).
   - If resolution fails: omit the mention; continue.

4. **Idempotency check.** Call `mcp__<tracker.mcp>__<operations.getComments>` for `{ID}`. Scan comment bodies for a line matching `n1-escalation: n1-esc-{ID}-` that corresponds to the same `{step}` (check the comment body for `step **{step}**`). If found, skip posting — the escalation was already posted. Set `marker` to the existing value. Jump to step 6 (write tracker-state.json) using the existing marker.

5. **Post comment.** Compute `epoch` via Bash:
   ```bash
   epoch=$(date +%s)
   ```
   Build the marker: `n1-esc-{ID}-${epoch}`.

   Comment format:
   ```
   {mention} N1 is blocked on {ID} at step **{step}** and needs your input.

   Q1: {questions[0].text}
   Options:
   1 — {questions[0].options[0]}
   2 — {questions[0].options[1]}
   ...
   Recommended: {questions[0].recommendation}
   Context: {questions[0].context}

   [repeat Q<n> block for each question]

   Reply in a comment using this format (plain language also accepted):
   N1: Q1=1 guidance: <optional free-text for N1 to use>

   n1-escalation: n1-esc-{ID}-${epoch}
   ```

   Call `mcp__<tracker.mcp>__<operations.addComment>` with this body. Capture the returned comment ID as `comment_id`.

6. **Write tracker-state.json.** Write `$N1_HOME/memory/{ID}/tracker-state.json`:
   ```json
   {
     "run_id": "{N1_RUN_ID}",
     "step": "{step}",
     "marker": "n1-esc-{ID}-{epoch}",
     "posted_at": "<ISO-8601 timestamp from date -u +%Y-%m-%dT%H:%M:%SZ>",
     "comment_id": "{comment_id}",
     "questions": [{questions array}],
     "previous_status": "{previous_status}",
     "moved_to_blocked": true|false,
     "mention": "{resolved mention string or empty}"
   }
   ```

7. **Update overview.md Pending block.** Append or create a `## Pending` section in `$N1_HOME/memory/{ID}/overview.md`:
   ```
   awaiting: reply
   blocked_since: <date -u +%Y-%m-%dT%H:%M:%SZ>
   ```
   Use `sed -i` or a full-rewrite via Bash — do not leave duplicate `## Pending` sections.

---

## Resume-from-Tracker Procedure

**Trigger:** called when `$N1_HOME/memory/{ID}/tracker-state.json` exists at the start of any resume.

1. **Guard.** If `tracker-state.json` does NOT exist → skip this procedure entirely; proceed with normal resume.

2. **Read state.** Parse `tracker-state.json`: extract `run_id`, `step`, `marker`, `posted_at`, `questions`, `previous_status`, `moved_to_blocked`.

3. **Fetch candidate reply comments.** Call `mcp__<tracker.mcp>__<operations.getComments>` for `{ID}`. Filter the result:
   - Keep only comments where `created > posted_at`.
   - Exclude comments whose body contains a line starting with `n1-escalation: n1-esc-` (this excludes N1's own escalation and ack comments — marker exclusion, not author-based, because N1 posts as the user's token).

4. **No candidates — no reply yet.**
   - **Interactive mode:** re-present the questions inline to the user directly (do not re-post to tracker). Wait for the user's answer and continue.
   - **Step mode:** re-emit the escalation — write `request.json` from the stored `questions` array (preserve original `run_id` from tracker-state.json), emit step result:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
     n1_emit_step_result "{step}" "escalation" "null" "null" "" "$N1_HOME/memory/{ID}"
     ```
     STOP.

5. **Parse reply.** Model-side parsing — latest comment per question wins:
   - **Structured:** scan for `N1: Q<n>=<index>` patterns. `choice_index` = index − 1 (0-based). Optional `guidance:` suffix is the `text` field.
   - **Plain language fallback:** if no structured pattern, interpret the comment body against each question's options using judgment. Map to the closest `choice_index`.
   - Build `answers` array:
     ```json
     [{ "id": "{questions[n].id}", "choice_index": <0-based>, "choice": "<option label>", "text": "<guidance or empty>" }]
     ```

6. **Materialize response.json.** Write `$N1_HOME/memory/{ID}/escalation/response.json`:
   ```json
   { "run_id": "{run_id from tracker-state.json}", "answers": [{answers array}] }
   ```
   Create the `escalation/` directory if needed.

7. **Restore ticket status.** If `moved_to_blocked` is `true`:
   - Read current ticket status via `mcp__<tracker.mcp>__<operations.readTicket>`.
   - If current status matches `tracker.statuses.blocked` (or `previous_status` is not already the current status): call `mcp__<tracker.mcp>__<operations.moveStatus>` to transition back to `previous_status`. Degrade silently on failure — never hard-fail.

8. **Post acknowledgement comment.** Post a brief comment so future scans exclude it:
   ```
   N1 received your reply for {ID} at step **{step}**. Resuming pipeline.

   n1-escalation: n1-esc-{ID}-ack
   ```

9. **Clean up state.**
   - Delete `$N1_HOME/memory/{ID}/tracker-state.json`.
   - Remove `awaiting: reply` and `blocked_since:` lines from overview.md `## Pending` section. If the section is now empty, remove the `## Pending` header too.
   - Append to overview.md `## Escalations`:
     ```
     - {step}: tracker reply received, pipeline resumed ({date})
     ```

10. **Continue normal resume flow.** The `response.json` is now in place — the calling step's on-re-run logic reads it as usual.
