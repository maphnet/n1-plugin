# Finish Hand-off (`handoff:yes` only)

The entry prints `handoff:yes` only for a chained headless run without ssh delivery, without done-status recovery and with post-deploy verification off, so Steps 3-6 hold no user prompt. Steps 1-2 and every merge gate already ran here. This file is reached only from a "Go to Step 3" or "Go to Step 4" in Step 2 or 2b.

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
head_ref: <headRefName>
worktree: <printed worktree:>
memory: <printed memory:>
n1_root: <printed n1_root:>
N1_HEADLESS: 1
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
[ "$T" != complete ] || { [ -s "$M/finish-block.md" ] && [ -s "$M/finish-report.md" ]; } || T=
echo "tail:${T:-unknown}"
[ -z "$T" ] || sed -n 's/^reason: //p' "$M/finish-result.md" | head -1
```

- `tail:complete` → run 06 § One Cleanup Call with `finish-block.md` as the `## Finish` block (no `getIssueLinks` call; the report already has Next tickets). Replace `Cleanup: <pending>` in the report with the cleanup tokens, print the Report, then do 06 release routing.
- `tail:stopped` → run `source ~/.n1/preamble.sh; n1_active_run_clear_if n1-finish` (every STOP does, per Step 1), then print "Finish stopped after the merge: <reason>. Fix it, then re-run `/n1:n1-finish <ID>`." **STOP**: no cleanup, no release routing. The worker already wrote any escalation and tracker comment its step requires.
- `tail:unknown` (no result, garbage, or complete without block or report) → add `- finish: tail-worker returned no status; re-run /n1:n1-finish <ID>` under `## Escalations` in overview.md, post the same text as an `N1 [headless]` tracker comment, then handle it as `tail:stopped`.
