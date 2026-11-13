# Finish Hand-off (`handoff:yes` only)

The entry prints `handoff:yes` when Steps 3-6 hold no predictable prompt: no pending-deploy resume, no ssh delivery, no done-status recovery, post-deploy verification off. Attended and headless runs both hand off; a question the attended worker meets anyway (the deployment-actions § Walk) comes back as `tail:prompt`, and Steps 3-6 then run inline. Steps 1-2 and every merge gate already ran here. This file is reached only from a "Go to Step 3" or "Go to Step 4" in Step 2 or 2b.

## Dispatch

```bash
source ~/.n1/preamble.sh
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
M="$N1_HOME/memory/$ID"; rm -f "$M/finish-result.md" "$M/finish-block.md" "$M/finish-report.md"
IFS=$'\t' read -r TM _ < <(n1_resolve_agent tail-worker finish)
echo "model:$TM"; echo "memory:$M"; echo "n1_root:$N1_ROOT"; echo "worktree:$(git rev-parse --show-toplevel)"
```

Dispatch persona `tail-worker` with the printed model and only this prompt (values from Steps 1-2 and the entry output), then wait for it, foreground, per `<N1_ROOT>/skills/n1-start/procedures/output-gates.md § Wait Contract`:

```
mode: finish
id: <ID>
pr: <PR number; empty on local merge>
merge_sha: <merge commit SHA>
merge_method: <squash|merge|rebase>
merged_by: <reviewer|n1-finish (mergeOnFinish)|local merge>
local_merge: <0|1>
comments: <reviewer: n/a (already merged)|n1-finish: no unresolved comments|local merge: n/a (local merge)>
head_ref: <headRefName>
worktree: <printed worktree:>
memory: <printed memory:>
n1_root: <printed n1_root:>
N1_HEADLESS: <1 when the entry printed headless:yes, else empty>
N1_QUEUE_RUN_ID: <value, or empty>
entry: <the entry output lines from `id=` through `read-also:`, verbatim>
```

## Result

Run this call and, in the same turn, read `steps/06-cleanup.md`, `<memory>/finish-block.md` and `<memory>/finish-report.md`:

```bash
source ~/.n1/preamble.sh
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
M="$N1_HOME/memory/$ID"
T=$(sed -nE 's/^status: (complete|stopped)\r?$/\1/p' "$M/finish-result.md" 2>/dev/null | tail -1)
B="$M/finish-block.md"
[ "$T" != complete ] || { [ -s "$M/finish-report.md" ] && [ "$(head -1 "$B" 2>/dev/null | tr -d '\r')" = "## Finish" ] && [ "$(grep -c '^## ' "$B" 2>/dev/null)" = 1 ]; } || T=
[ "$T" = stopped ] && [ "${N1_HEADLESS:-}" != 1 ] && grep -q '^reason: prompt: ' "$M/finish-result.md" && T=prompt
echo "tail:${T:-unknown}"
[ -z "$T" ] || sed -n 's/^reason: //p' "$M/finish-result.md" | head -1
```

- `tail:complete` → run 06 § One Cleanup Call with the heredoc replaced by `cat "$N1_HOME/memory/$ID/finish-block.md" >> "$OV"` (never paste the file's text into a command; Result already checked it is one `## Finish` section) (no `getIssueLinks` call; the report already has Next tickets). Replace `Cleanup: <pending>` in the report with the cleanup tokens, print the Report, then do 06 release routing. The call's last line, `n1_clean_ticket`, replaces `finish-report.md`'s `Cleanup: <pending>` with the real tokens (print them in the final Report).
- `tail:prompt` (attended only: the worker stopped before a question, e.g. the deployment-actions § Walk; passing `check` items never stop it) → read `steps/03-deploy.md`, `steps/04-close-ticket.md`, `steps/05-telemetry-followup.md` and `steps/06-cleanup.md`, then run Steps 3-6 inline from Step 3 (Step 4 when `local_merge` is 1), exactly as with `handoff:no`; the question reaches the user there. Step 3 re-checks the finished deploy, as a `/n1:n1-finish <ID>` re-run does.
- `tail:stopped` → run `source ~/.n1/preamble.sh; n1_active_run_clear_if n1-finish` (every STOP does, per Step 1), then print "Finish stopped after the merge: <reason>. Fix it, then re-run `/n1:n1-finish <ID>`." **STOP**: no cleanup, no release routing. The worker already wrote any escalation and tracker comment its step requires.
- `tail:unknown` (no result, garbage, or complete without a valid block or report) → attended (the entry printed no `headless:yes`): handle it as `tail:prompt` (Steps 3-6 inline; they re-check the finished work). Headless: add `- finish: tail-worker returned no status; re-run /n1:n1-finish <ID>` under `## Escalations` in overview.md, post the same text as an `N1 [headless]` tracker comment, then handle it as `tail:stopped`.
