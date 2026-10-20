<!-- Purpose: Display setup summary and next steps to the user. -->

## Confirm

Show summary:
```
N1 is ready.

State directory: ~/.n1/<project-name>/
Worktree setup: <command or "none">

Tracker: Jira (TRID) / YouTrack / None
Default branch: main
Branch pattern: {prefix}-{id}
Ticket tagging: payments-api / disabled
Error tracking: Sentry (my-backend @ my-org) / disabled
Local testing: enabled / disabled
Post-deploy verification: enabled / disabled (legacy smoke fallback when not configured)
Test coverage: maintain / minimal / standard
Telemetry: enabled / disabled
Story workflow: enabled (article/ticket/file) / disabled
PR mode: draft / ready

Created:
  ~/.n1/<project-name>/config.json
  ~/.n1/<project-name>/memory/
  ~/.n1/<project-name>/dev-access.md (when post-deploy verification was enabled)
  N1_HOME auto-derived from repo name (no git config needed)
  .gitignore configured (${WT_ROOT}/ — global or project-level)
  .claude/settings.json updated (if pinning configured)

Next: Use /n1:n1-start <ticket-or-description> to begin working on a task.
```

If `tracker.mcp` is not null, append after the summary:
```
To activate tracker routing, reload the session: type /clear or restart Claude Code.
```
