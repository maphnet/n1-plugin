# Procedure: Blocker Watch (n1-start, interactive)

Loaded only from `references/blocker-check.md` § Report branch 4 (interactive run with open blockers). The ticket step has already ended `blocked`; the tracker status is untouched. One background shell checks every open blocker every 30 minutes for at most 3 hours with no model turn between checks. It ends with the session; `/n1:n1-start <ID>` re-checks after a restart.

## 1. Keys

Take `<KEY>` from each `OPEN_BLOCKERS` line. Keep only keys that match `^[A-Z][A-Z0-9_]*-[0-9]+$`; never write any other key, a title or a status into a command. No key left: print `Stopped: <ID> is blocked by open blockers. Finish or unlink them; /n1:n1-start <ID> resumes and re-checks.` and end the run.

## 2. Mode

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/ticket-watch.sh"; source "$N1_ROOT/lib/poll.sh"
n1_blocker_watch_mode | cut -d' ' -f1
```

Output `pr-only`: print once `Blocker watch: no tracker HTTP endpoint, checking PR state only.`

## 3. Launch

Run in the background this one command, with `<ID>` and the kept keys as separate trailing arguments (they arrive as argv, never inside the quoted script):

```bash
bash -c 'source ~/.n1/preamble.sh; source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/ticket-watch.sh"; source "$N1_ROOT/lib/poll.sh"; n1_blocker_watch "$@"' _ <ID> <KEY> [<KEY>...]
```

Then print `Stopped: <ID> is blocked by <KEYS>. Watching the blockers every 30 min for up to 3h; the run resumes when all are resolved. /n1:n1-start <ID> re-checks at any time.` and end the run. Do not wait for the watch.

## 4. Notice

When the background command exits, read its one output line. Ask nothing.
- `RESOLVED <ID>: ...`: invoke skill n1-start with `<ID>`. It re-runs the blocker check.
- `TIMEOUT <ID> comment:posted <text>`: print `<text>`. The watch already wrote it under `## Escalations` in overview.md and posted the tracker comment. Stop.
- `TIMEOUT <ID> comment:pending <text>`: the escalation line is already in overview.md. Post the tracker comment via `mcp__<tracker.mcp>__<tracker.operations.addComment>` (Jira: include `cloudId`; skip when either config value is empty) with the body `N1 [blocker-watch] <ID> <text>. Run /n1:n1-start <ID> to re-check.`, a blank line, then `n1-esc:<ID>:ticket`. A failed post only warns. Print `<text>`. Stop.
- `ERROR bad-key` or any other output: print `Blocker watch stopped: <line>. /n1:n1-start <ID> re-checks.` Stop.
