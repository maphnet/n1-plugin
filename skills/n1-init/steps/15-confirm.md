<!-- Purpose: Display setup summary and next steps to the user. -->

## Confirm

Show summary:
```
N1 is ready.

State directory: ~/.n1/<project-name>/
Host: claude-code / codex (personas: .codex/agents/n1-*.toml, hooks trusted)
Worktree mode: worktree
Worktree setup: <command or "none">
Worktree cleanup: after-merge

Tracker: Jira (TRID) / YouTrack / None
Default branch: main
Branch pattern: {prefix}-{id}
Ticket tagging: payments-api / disabled
Error tracking: Sentry (my-backend @ my-org) / disabled
Estimation: enabled (default mapping) / enabled (custom mapping) / disabled
Local testing: enabled / disabled
Test coverage: maintain / minimal / standard
Telemetry: enabled / disabled
Story workflow: enabled (article/ticket/file) / disabled
PR mode: draft / ready

Created:
  ~/.n1/<project-name>/config.json
  ~/.n1/<project-name>/memory/
  N1_HOME auto-derived from repo name (no git config needed)
  .gitignore configured (${WT_ROOT}/ — global or project-level)
  .claude/settings.json updated (if pinning configured)

Next: Use /n1:n1-start <ticket-or-description> to begin working on a task.
```

If `tracker.mcp` is not null, append after the summary:
```
To activate tracker routing, reload the session: type /clear or restart Claude Code (on Codex: start a new session).
```
