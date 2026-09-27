# Delivery Deploy (SSH)

Entered from the top of Step 4 (`04-close-ticket.md`) only, after the merge (Step 2 / 2b) and the deploy watch (Step 3). This step deploys the merged change to the project's host with the project-owned `delivery.command`, then checks the result with `delivery.verifyCommand`.

`<SHA>` below is the merge SHA from Step 2 / 2b, or `deploy_merge_sha` on a resume (Step 1). It is empty when nothing has been merged yet.

```bash
source ~/.n1/preamble.sh
echo "delivery:$(n1_delivery_action)"
```

- `delivery:none` means `delivery.mode` is not `"ssh"`. There is nothing to do: return to Step 4 and continue exactly as before.
- `delivery:runbook` → Runbook branch.
- `delivery:execute` → Execute branch.

## Runbook branch (queue and headless runs, never executes)

Queue children and headless runs **never** run `delivery.command` or `delivery.verifyCommand`, not even to check something, and never run `ssh`, `scp` or `rsync` against the project host. The human deploys later with `n1-finish <ID>`.

1. Write the runbook and mark the ticket as deploy-pending:
   ```bash
   source ~/.n1/preamble.sh
   n1_delivery_runbook "<ID>" "<SHA>"
   ```
2. When `tracker.mcp` is set, post the content of the printed runbook file as a comment via `mcp__<tracker.mcp>__<operations.addComment>`, prefixed with `N1: deploy pending.` When `operations.getComments` exists, skip the comment if an identical one is already present. If the tracker call fails, warn and continue; never block.
3. Add this line to the `## Finish` section of overview.md: `- **Deploy:** pending (runbook: memory/<ID>/runbook.md)`.
4. Do **not** close the ticket. Skip the rest of Step 4 and Step 5 and go to Step 6.

The queue runner reads `deploy_pending: true` and parks the row as `awaiting-human` (Reason `awaiting-deploy`). The queue then moves on to the next ticket.

## Execute branch (interactive runs only)

1. Read the commands:
   ```bash
   source ~/.n1/preamble.sh
   echo "command:$(n1_config_val '.delivery.command')"
   echo "verify:$(n1_config_val '.delivery.verifyCommand')"
   ```
   If the command is empty, report "`delivery.mode` is \"ssh\" but `delivery.command` is empty. Set it in `$N1_HOME/config.json`." Do not close the ticket. **STOP.**
2. Ask the user. This is an unconditional gate: never auto-resolve it and never pick an option on the user's behalf.
   ```
   Deploy <ID> now?
   Command: <delivery.command>
   Verify:  <delivery.verifyCommand, or "none (the deploy exit code is the only check)">
   1 — Yes, deploy now
   2 — No, leave the ticket open
   ```
3. **No** → run Runbook branch steps 1–3. This records the pending deploy so that `n1-finish <ID>` resumes here without merging again. Report "Deploy skipped. Run `n1-finish <ID>` when ready." **STOP.**
4. **Yes** → deploy:
   ```bash
   source ~/.n1/preamble.sh
   DEPLOY_CMD=$(n1_config_val '.delivery.command')
   OUT=$(bash -c "$DEPLOY_CMD" 2>&1); DEPLOY_EXIT=$?
   printf '%s\n' "$OUT" | tail -100
   echo "deploy-exit:$DEPLOY_EXIT"
   ```
5. **Non-zero `deploy-exit`** → run Runbook branch step 1. If a tracker is configured, add a comment: "Deploy failed (exit <N>) for <ID>: `<command>`" followed by the last 50 output lines. Report the output and "Fix the cause, then re-run `n1-finish <ID>`." Do not close the ticket. **STOP.**
6. **Verify:** when `verify:` printed an empty value, record verify as `not configured` and go to step 7. Otherwise run:
   ```bash
   source ~/.n1/preamble.sh
   VERIFY_CMD=$(n1_config_val '.delivery.verifyCommand')
   OUT=$(bash -c "$VERIFY_CMD" 2>&1); VERIFY_EXIT=$?
   printf '%s\n' "$OUT" | tail -100
   echo "verify-exit:$VERIFY_EXIT"
   ```
   A non-zero `verify-exit` is handled like step 5, with "Deploy verification failed (exit <N>)". **STOP.**
7. **Success:** clear the pending flag and record the result:
   ```bash
   source ~/.n1/preamble.sh
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   ```
   Add this line to the `## Finish` section of overview.md: `- **Deploy:** succeeded (<verified | not verified>)`. Return to Step 4 and continue. Step 4's close comment gets the delivery suffix.
