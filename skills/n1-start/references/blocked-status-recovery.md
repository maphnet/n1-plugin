# Blocked-Status Runtime Recovery

When Post-to-Tracker is attempted but `tracker.statuses.blocked` is absent from config, use this auto-match-or-degrade procedure. Pattern mirrors `skills/n1-finish/references/done-status-recovery.md`.

---

## Procedure

1. **Detect available statuses.**
   - Jira: call `mcp__<tracker.mcp>__<operations.getTransitions>` on the current ticket; extract the target status name from each transition.
   - YouTrack: call `mcp__<tracker.mcp>__<operations.readTicket>` on the current ticket; inspect the State field for available values. Fallback: search for one sample issue in the project and read its State field.
   - **If detection fails** (MCP error or empty result): degrade to comment-only. Do not prompt or hard-fail. Set `moved_to_blocked: false` and continue.

2. **Auto-match.** Names matching any of ("Blocked", "On Hold", "Waiting", "Paused") — case-insensitive substring — are candidates. Sort matched names first.

3. **If exactly one candidate or a clear best match:** use it for the current run only. Do NOT persist to `config.json` without the user's explicit confirmation (unlike done-status, where n1-init already set it). Set `moved_to_blocked: true`.

4. **If multiple candidates:** pick the first sorted match. Use for the current run only. Do not persist.

5. **If no match:** degrade to comment-only. Set `moved_to_blocked: false`. Post the escalation comment as normal — the blocked-status step is simply skipped.

Auto-match applies to this escalation run only. The matched value is held in memory for the duration of the Post-to-Tracker procedure and discarded afterward. Re-run `/n1:n1-init` to configure `tracker.statuses.blocked` persistently.
