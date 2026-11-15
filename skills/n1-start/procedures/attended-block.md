# Procedure: Attended Block

Read before a blocking question in an attended run at the sites that point here. Headless and queue runs (`N1_HEADLESS=1`) use `procedures/autonomy-headless.md § Headless Guard` instead. Every move here is best-effort: it never gates, retries or delays the question.

## Block (before the ask)

```bash
source ~/.n1/preamble.sh
[ "${N1_HEADLESS:-}" = "1" ] && echo "ATTENDED_BLOCK=skip:headless"
printf 'BLOCKED_STATUS=%s\nIN_PROGRESS_STATUS=%s\nTRACKER_TYPE=%s\n' "$(n1_config_val '.tracker.statuses.blocked')" "$(n1_config_val '.tracker.statuses.inProgress')" "$(n1_config_val '.tracker.type')"
```

Read the values from this output only. No move and no flag when `ATTENDED_BLOCK=skip:headless` printed, `BLOCKED_STATUS` is empty, `IN_PROGRESS_STATUS` is empty, `BLOCKED_STATUS` equals `IN_PROGRESS_STATUS`, or the run has no tracker ticket ID: ask the question.

Otherwise move the ticket to `BLOCKED_STATUS` as `procedures/autonomy-headless.md § Headless Guard` escalation step 1 describes (Jira: getTransitions to find the transition, then moveStatus; other trackers: moveStatus), with one override: the move is best-effort, not mandatory. On a tool error print one line `WARN: blocked move failed: <error>` and go straight to the question, with no retry and no flag. Do not touch `original_status`. Never write `step: escalated` here.

On a successful move only:

```bash
source ~/.n1/preamble.sh
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "blocked_wait" "true"
```

Then ask the question.

## Unblock (after the answer)

On any answer except stop (Gate 2: approval or a plan-change reply):

```bash
source ~/.n1/preamble.sh
echo "BLOCKED_WAIT=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "blocked_wait")"
printf 'IN_PROGRESS_STATUS=%s\n' "$(n1_config_val '.tracker.statuses.inProgress')"
```

`BLOCKED_WAIT=true`: move the ticket to `IN_PROGRESS_STATUS` the same way (Jira: getTransitions lookup targeting it, then moveStatus), best-effort (a tool error prints `WARN: in-progress move failed: <error>`), then, whatever the move outcome:

```bash
source ~/.n1/preamble.sh
n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "blocked_wait" "false"
```

Any other `BLOCKED_WAIT`: nothing to do. Continue with the answer.

## Stop

On "stop", or when the run ends at the question: do nothing. The ticket stays Blocked and `blocked_wait` stays `true`; `procedures/resume.md` moves it back to In Progress on the next `/n1:n1-start <ID>`.
