# Delivery Deploy (SSH)

Entered from the top of Step 4 (`04-close-ticket.md`) only, after the merge (Step 2 / 2b) and the deploy watch (Step 3). This step deploys the merged change to the project's host with the project-owned `delivery.command` (or, step by step, the ordered `delivery.steps` list), then checks the result with `delivery.verifyCommand`.

`<SHA>` below is the merge SHA from Step 2 / 2b, or `deploy_merge_sha` on a resume (Step 1). It is empty when nothing has been merged yet.

```bash
source ~/.n1/preamble.sh
echo "delivery:$(n1_delivery_action)"
```

- `delivery:none` means `delivery.mode` is not `"ssh"`. There is nothing to do: return to Step 4 and continue exactly as before.
- `delivery:runbook` → Runbook branch.
- `delivery:execute` → Execute branch.

## Runbook branch (queue and headless runs, never executes)

Queue children and headless runs **never** run `delivery.command`, any `delivery.steps` item, or `delivery.verifyCommand`, not even to check something, and never run `ssh`, `scp` or `rsync` against the project host. The human deploys later with `n1-finish <ID>`.

1. Write the runbook and mark the ticket as deploy-pending:
   ```bash
   source ~/.n1/preamble.sh
   n1_delivery_runbook "<ID>" "<SHA>"
   ```
2. When `tracker.mcp` is set, post a short comment via `mcp__<tracker.mcp>__<operations.addComment>`: `N1: Deploy pending — resume with /n1:n1-finish <ID> (runbook in N1 memory).` Never post the runbook content or the `delivery.command`/`delivery.steps`/`delivery.verifyCommand` text itself — it may contain hosts, paths, or secrets, and the runbook is local-only. When `operations.getComments` exists, skip the comment if an identical one is already present. If the tracker call fails, warn and continue; never block.
3. Add this line to the `## Finish` section of overview.md: `- **Delivery:** pending (runbook: memory/<ID>/runbook.md)`.
4. Do **not** close the ticket. Skip the rest of Step 4 and Step 5 and go to Step 6.

The queue runner reads `deploy_pending: true` and parks the row as `awaiting-human` (Reason `awaiting-deploy`). The queue then moves on to the next ticket.

## Execute branch (interactive runs only)

1. Read the delivery shape and the commands. Execution requires `jq` — `n1_delivery_action` already returns `runbook` (not `execute`) when `jq` is unavailable, so reaching this branch means `jq` is present and the values below are parsed safely.
   ```bash
   source ~/.n1/preamble.sh
   echo "multi-step:$(n1_delivery_is_multi_step)"
   echo "command:$(n1_config_val '.delivery.command')"
   echo "verify:$(n1_config_val '.delivery.verifyCommand')"
   ```
   `multi-step:true` → go to the **Multi-step execute** section below; steps 2–7 here do not apply. Otherwise, if the command is empty, report "`delivery.mode` is \"ssh\" but `delivery.command` is empty. Set it in `$N1_HOME/config.json`." Do not close the ticket. **STOP.**
2. Ask the user. This is an unconditional gate: never auto-resolve it and never pick an option on the user's behalf.
   ```
   Deploy <ID> now?
   Command: <delivery.command>
   Verify:  <delivery.verifyCommand, or "none (the deploy exit code is the only check)">
   1 — Yes, deploy now
   2 — No, leave the ticket open
   ```
3. **No** → run Runbook branch steps 1–3. This records the pending deploy so that `n1-finish <ID>` resumes here without merging again. Report "Deploy skipped. Run `n1-finish <ID>` when ready." **STOP.**
4. **Yes** → deploy. Both commands run from a temporary detached checkout of `<SHA>` (never the current directory, which may be the feature worktree), so `./deploy.sh` or `rsync ./ …` ship exactly the merged revision. A checkout failure counts as a failed deploy.
   ```bash
   source ~/.n1/preamble.sh
   DEPLOY_DIR="${TMPDIR:-/tmp}/n1-deploy-<ID>"
   git worktree remove --force "$DEPLOY_DIR" 2>/dev/null || true
   git fetch -q origin 2>/dev/null || true
   if [ -n "<SHA>" ] && git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"; then
     DEPLOY_CMD=$(n1_config_val '.delivery.command')
     OUT=$(cd "$DEPLOY_DIR" && bash -c "$DEPLOY_CMD" 2>&1); DEPLOY_EXIT=$?
   else
     OUT="Cannot check out merge SHA '<SHA>' for the deploy."; DEPLOY_EXIT=1
   fi
   mkdir -p "$N1_HOME/memory/<ID>"
   printf '%s\n' "$OUT" > "$N1_HOME/memory/<ID>/deploy-output.log"
   printf '%s\n' "$OUT" | tail -100
   echo "deploy-exit:$DEPLOY_EXIT"
   ```
   Once the deploy (and the verify, when configured) has run — on every outcome of steps 5–7, before any **STOP** — remove the checkout:
   ```bash
   source ~/.n1/preamble.sh
   git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>" 2>/dev/null || true
   ```
5. **Non-zero `deploy-exit`** → run Runbook branch steps 1 and 3 (writes the runbook, marks the ticket deploy-pending, and adds the `- **Delivery:** pending (runbook: memory/<ID>/runbook.md)` line to overview.md). The deploy output stays local — it is not posted to the tracker; it was written to `memory/<ID>/deploy-output.log` above (may contain host/path/secret details). If a tracker is configured, add a comment: "Deploy failed (exit <N>) for <ID>; output kept locally in N1 memory." Report the output and "Fix the cause, then re-run `n1-finish <ID>`." Do not close the ticket. **STOP.**
6. **Verify:** when `verify:` printed an empty value, record verify as `not configured` and go to step 7. Otherwise run:
   ```bash
   source ~/.n1/preamble.sh
   VERIFY_CMD=$(n1_config_val '.delivery.verifyCommand')
   OUT=$(cd "${TMPDIR:-/tmp}/n1-deploy-<ID>" && bash -c "$VERIFY_CMD" 2>&1); VERIFY_EXIT=$?
   mkdir -p "$N1_HOME/memory/<ID>"
   printf '%s\n' "$OUT" > "$N1_HOME/memory/<ID>/deploy-output.log"
   printf '%s\n' "$OUT" | tail -100
   echo "verify-exit:$VERIFY_EXIT"
   ```
   A non-zero `verify-exit` is handled like step 5 (same runbook + local-log + finish-line + tracker comment), with "Deploy verification failed (exit <N>) for <ID>; output kept locally in N1 memory." **STOP.**
7. **Success:** clear the pending flag and record the result:
   ```bash
   source ~/.n1/preamble.sh
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   ```
   Add this line to the `## Finish` section of overview.md: `- **Delivery:** succeeded (<verified | not verified>)`. Return to Step 4 and continue. Step 4's close comment gets the delivery suffix.

## Multi-step execute (interactive runs only, `delivery.steps`)

Entered from Execute branch step 1 when `multi-step:true`. The `verify:` value printed there still applies. `delivery.steps` is an ordered list. Each item follows the `references/deployment-actions.md` grammar:
- An item starting with `Manual:` is a manual step.
- An item that starts with a backtick and has exactly two backticks is a shell step.
- Anything else is a manual step.

`n1_delivery_step` classifies the item and writes a shell step's command to `deploy-step.cmd`, so the bytes shown and the bytes run are identical. Never re-type a command.

This is an unconditional gate: ask the user for every step, never auto-resolve, never pick an option on the user's behalf, and never run a step the user has not confirmed in this run.

**Cleanup:** once the walk has started, run this on every outcome before any **STOP** or return:
```bash
source ~/.n1/preamble.sh
git worktree remove --force "${TMPDIR:-/tmp}/n1-deploy-<ID>" 2>/dev/null || true
rm -f "$N1_HOME/memory/<ID>/deploy-step.cmd"
```

1. Check out the merge SHA and find the first step. Steps run from a temporary detached checkout of `<SHA>`, as the single command does. A resumed deploy starts at `deploy_next_step`, which was recorded when an earlier walk stopped.
   ```bash
   source ~/.n1/preamble.sh
   DEPLOY_DIR="${TMPDIR:-/tmp}/n1-deploy-<ID>"
   git worktree remove --force "$DEPLOY_DIR" 2>/dev/null || true
   git fetch -q origin 2>/dev/null || true
   mkdir -p "$N1_HOME/memory/<ID>"
   : > "$N1_HOME/memory/<ID>/deploy-output.log"
   K=$(n1_read_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_next_step 2>/dev/null || true)
   case "$K" in ''|*[!0-9]*) K=0 ;; esac
   echo "start:$K"
   if [ -n "<SHA>" ] && git worktree add -q --detach "$DEPLOY_DIR" "<SHA>"; then echo "checkout:ok"; else echo "checkout:failed"; fi
   ```
   On `checkout:failed`:
   - Run Cleanup.
   - Run Runbook branch steps 1 and 3, calling `n1_delivery_runbook "<ID>" "<SHA>" <K>` in step 1 (use the `start:` value for `<K>`).
   - If a tracker is configured, add a comment: "Deploy failed for <ID>: cannot check out the merge SHA; nothing ran. Details kept locally in N1 memory."
   - Do not close the ticket. **STOP.**
2. Walk the steps, starting at `<K>` = the `start:` value. For each `<K>`:
   ```bash
   source ~/.n1/preamble.sh
   n1_delivery_step <K> "$N1_HOME/memory/<ID>/deploy-step.cmd"
   ```
   Line 1 is the kind; the remaining lines are the item text.
   - `end` with `<K>` = 0: report "`delivery.mode` is \"ssh\" but `delivery.steps` is empty. Set it in `$N1_HOME/config.json`." Run Cleanup. Do not close the ticket. **STOP.**
   - `end` with `<K>` > 0: every step has been offered. Go to step 3.
   - `shell`: show the command with `cat "$N1_HOME/memory/<ID>/deploy-step.cmd"` and never re-type it. Then ask:
     ```
     Deploy step <K+1> for <ID>: <item text>
     Command: <output of cat>
     Run this?
     1 — Yes
     2 — Skip
     3 — Abort
     ```
     On **Yes**, run:
     ```bash
     source ~/.n1/preamble.sh
     CMDF="$N1_HOME/memory/<ID>/deploy-step.cmd"
     OUT=$(cd "${TMPDIR:-/tmp}/n1-deploy-<ID>" && bash "$CMDF" 2>&1); STEP_EXIT=$?
     printf '== step <K+1> (exit %s) ==\n%s\n' "$STEP_EXIT" "$OUT" >> "$N1_HOME/memory/<ID>/deploy-output.log"
     printf '%s\n' "$OUT" | tail -100
     echo "step-exit:$STEP_EXIT"
     ```
     `step-exit:0` → next step (`<K+1>`). A non-zero exit → report the failure and ask `1 — Retry / 2 — Skip / 3 — Abort`. Retry runs the same snippet again (the same file, never re-typed).
   - `manual`: ask:
     ```
     Deploy step <K+1> for <ID> (manual): <item text>
     Done?
     1 — Yes, done
     2 — Skip (not done)
     3 — Abort
     ```
     **Yes, done** → next step.
   - **Skip** (including skipping a failed command) → note the step number and go to the next step.
   - **Abort** → step 5.
3. **Verify** once, after the walk. When `verify:` printed an empty value, record verify as `not configured` and go to step 4. Otherwise run:
   ```bash
   source ~/.n1/preamble.sh
   VERIFY_CMD=$(n1_config_val '.delivery.verifyCommand')
   OUT=$(cd "${TMPDIR:-/tmp}/n1-deploy-<ID>" && bash -c "$VERIFY_CMD" 2>&1); VERIFY_EXIT=$?
   printf '== verify (exit %s) ==\n%s\n' "$VERIFY_EXIT" "$OUT" >> "$N1_HOME/memory/<ID>/deploy-output.log"
   printf '%s\n' "$OUT" | tail -100
   echo "verify-exit:$VERIFY_EXIT"
   ```
   On a non-zero `verify-exit`:
   - Run Cleanup.
   - Run Runbook branch steps 1 and 3 as written. The two-argument call resets `deploy_next_step` to 0, so a resume offers every step again.
   - If a tracker is configured, add a comment: "Deploy verification failed (exit <N>) for <ID>; output kept locally in N1 memory."
   - Report the output and "Fix the cause, then re-run `n1-finish <ID>`." Do not close the ticket. **STOP.**
4. **Success:** run Cleanup, then clear the pending state:
   ```bash
   source ~/.n1/preamble.sh
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_pending false || true
   n1_write_frontmatter "$N1_HOME/memory/<ID>/overview.md" deploy_next_step 0 || true
   ```
   Add this line to the `## Finish` section of overview.md: `- **Delivery:** succeeded (<verified | not verified>; skipped steps: <numbers, or none>)`. Return to Step 4 and continue. Step 4's close comment gets the delivery suffix.
5. **Abort at step `<K+1>`:**
   - Run Cleanup.
   - Run Runbook branch steps 1–3, calling `n1_delivery_runbook "<ID>" "<SHA>" <K>` in step 1. This lists step `<K+1>` onward and records `deploy_next_step`. Step 2's comment carries no step text, and any failed step's output stays in `memory/<ID>/deploy-output.log`, kept locally in N1 memory.
   - Report which steps ran, which were skipped (they are not offered again on resume, so do them by hand if needed), and which remain.
   - Report "Run `n1-finish <ID>` to continue from step <K+1>." Do not close the ticket. **STOP.**
