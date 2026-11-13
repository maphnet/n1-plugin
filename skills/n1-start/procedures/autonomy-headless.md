# Procedure: Autonomy Gate and Headless Guard

Covers the quality autonomy gate and the headless guard for non-interactive runs.

## Autonomy Gate

When a quality step has findings that the user would normally be prompted about, check the autonomy policy first.

**Parameters:** `{step}`, `{action}` (what auto-accept does, e.g. "accept remaining findings"), `{ledger_context}` (summary for the Decision Ledger row)

**If the findings do NOT involve security, architecture, or public API changes:** take `{action}` silently. Append a Decision Ledger row to overview.md:

`| {step} | quality | A | [auto] | {ledger_context} | {action} | Prompt user | auto-accept | --- |`

**If the findings involve security/architecture/public API:** show the interactive prompt as defined by the step file.

**Headless:** under `N1_HEADLESS=1`, apply § Headless Guard below instead of prompting.

## Headless Guard

Applies whenever the environment variable `N1_HEADLESS` equals `1` (the run was launched by `n1-queue` or another non-interactive parent). There is no user to answer prompts directly.

When `N1_UNATTENDED` also equals `ask` (set for Claude Code queue children), an escalation pauses and asks the user instead of ending the run — see the ask-mode branch below. Any other headless run (`-p` children, or `N1_HEADLESS=1` with `N1_UNATTENDED` unset) keeps the escalate-and-exit path unchanged.

At any point where a step would ask the user or otherwise **wait for the user**, classify the prompt against the **stop list** before escalating.

**Stop list:** the categories in `n1_escalation_val 'alwaysAskOn'` (default: `security`, `architecture`, `public-api`) plus the release confirmation gate (always unconditional). A `[refined]` Decision (n1-refine block) never settles a stop-list prompt: classify the prompt as usual and escalate unless the plan-time pre-decision below applies.

**Review fix budget exhausted (N1-569):** not a Headless Guard prompt. `steps/fix.md` **Exhausted** takes the For Human Review exit in headless runs, open `[SEC-N]` included: no pause, the PR opens, and a FAIL verdict is never merged. A developer `needs-decision` on a stop-list category still comes here (`procedures/review-fix-budget.md § Needs decision`).

**Plan-time pre-decision (queue children).** If the prompt is in a stop-list category (never the release gate) and the run was launched by n1-queue, read `procedures/autonomy-headless-predecision.md` and follow it: it either logs a `[plan]` row and continues, or falls through to the escalation below.

**If the prompt is NOT on the stop list AND the step has a recommended option** (the option marked "(Recommended)" or listed first as default): take the recommended option silently. Log it:

```bash
source ~/.n1/preamble.sh
OVERVIEW="$N1_HOME/memory/$ID/overview.md"
grep -q '^## Decision Ledger' "$OVERVIEW" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OVERVIEW"
printf '| %s | headless | %s | [auto] | %s | %s | %s | headless: not on stop list | --- |\n' "$STEP" "$TIER" "$QUESTION" "$RECOMMENDED" "$ALTERNATIVES" >> "$OVERVIEW"
```

Then continue the run — do not escalate, do not end — unless the recommended option ends the run (next branch).

**If the recommended option ends the run** (it stops the pipeline with no code change, e.g. the analysis contradiction gate's Redirect for an obsolete or already-done ticket): log the ledger row above, then escalate so the launching session sees why; never end silently:

1. Append to `## Escalations`; keep the fixed phrase `ticket obsolete:` (the queue runner matches it to release overlap successors):
   ```bash
   source ~/.n1/preamble.sh; source "$N1_ROOT/lib/memory.sh"
   n1_append_escalation "$N1_HOME/memory/$ID/overview.md" "$(printf -- '- [headless] %s: ticket obsolete: %s' "$STEP" "$EVIDENCE")"
   ```
2. Run escalation steps 3 (release the queue tag) and 4 (tracker comment; reason line `ticket obsolete: <evidence>`, no options line) below.
3. Skip the blocked move (step 1) and the ask-mode branch whatever `N1_UNATTENDED` is: nothing is left to answer. Run step 5 "Not `ask`" a-b below: set `step: escalated`, run the telemetry failure path, clear the active-run pointer, print `HEADLESS ESCALATION: <one line>` and end the run.

**If the prompt IS on the stop list, is the release gate, or has no recommended option**, escalate:

1. **Resolve the blocked status and perform the mandatory move** (runs first so its outcome can be recorded in the escalations line):
   ```bash
   source ~/.n1/preamble.sh
   BLOCKED_STATUS=$(n1_config_val '.tracker.statuses.blocked')
   TRACKER_TYPE=$(n1_config_val '.tracker.type')
   printf 'BLOCKED_STATUS=%s\nTRACKER_TYPE=%s\n' "$BLOCKED_STATUS" "$TRACKER_TYPE"
   ```
   - Read `BLOCKED_STATUS=` from the command output above (never from memory or config recall); if it is empty: outcome is `skipped:no-blocked-status`; do not move.
   - Otherwise the move is **mandatory** (not best-effort — this differs from the comment below): on Jira, call `mcp__<tracker.mcp>__<operations.getTransitions>` first to find the transition ID targeting `BLOCKED_STATUS`, then call `mcp__<tracker.mcp>__<operations.moveStatus>`; on other trackers call `moveStatus` directly with `BLOCKED_STATUS`. Do not overwrite the existing `original_status` frontmatter. Outcome is `moved` on success, `failed:<error>` on any tool-call error.
2. Append to `## Escalations` in `$N1_HOME/memory/$ID/overview.md`, including the resolved outcome:
   ```bash
   source ~/.n1/preamble.sh; source "$N1_ROOT/lib/memory.sh"
   n1_append_escalation "$N1_HOME/memory/$ID/overview.md" "$(printf -- '- [headless] %s: %s, options: %s (blocked-move: %s)' "$STEP" "$QUESTION" "$OPTIONS" "$MOVE_OUTCOME")"
   ```
3. **Release the queue tag** (best-effort, queue children only):
   ```bash
   source ~/.n1/preamble.sh
   printf 'N1_QUEUE_TAG=%s\n' "${N1_QUEUE_TAG:-}"
   ```
   Empty -> skip (not launched by a tag-mode queue). Otherwise read and follow `<N1_ROOT>/skills/n1-queue/procedures/release-tag.md` with `ID`, `TAG=<N1_QUEUE_TAG>`, `OVERVIEW=$N1_HOME/memory/$ID/overview.md`; keep its `TAG_RELEASE` outcome for the comment.
4. Post a comment via `mcp__<tracker.mcp>__<operations.addComment>` (best-effort — a failure here never blocks the escalation):
   ```
   N1 [headless] <step>: <one-line reason>
   <question(s) and options, one per line>
   Queue tag removed — re-add "<tag>" to re-queue this ticket.
   Memory: $N1_HOME/memory/<ID>/
   Resume: /n1:n1-start <ID>
   n1-esc:<ID>:<step>
   ```
   The last line is an idempotency marker. Before posting on YouTrack, fetch comments via `mcp__<tracker.mcp>__<operations.getComments>` and skip if any comment contains `n1-esc:<ID>:<step>`. On Jira, skip the duplicate check (no listed getComments op) and post directly.
   Include the `Queue tag removed` line only when the release outcome is `removed`; omit it otherwise.
5. Branch on `N1_UNATTENDED`:

   **Not `ask`** (`-p` children, or `N1_HEADLESS=1` alone) — escalate-and-exit, unchanged:
   a. Set frontmatter `step: escalated`:
      ```bash
      source ~/.n1/preamble.sh
      n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "escalated"
      ```
   b. Run the telemetry failure path from **Error Recovery** (emit `outcome: "failed"` for the current step, merge), clear the active-run pointer, print `HEADLESS ESCALATION: <one line>` and **end the run**. Do not retry, do not continue to later steps.

   **`ask`** (Claude Code queue children) — ask-mode, pause instead of ending: read `procedures/autonomy-headless-ask.md` and follow its steps a-d.

A later `/n1:n1-start <ID>` in an interactive session resumes at the escalated step and asks the question normally (resume support reads `## Escalations`; on resume with `N1_HEADLESS` unset, reset `step` to the last completed step before continuing).

Mechanical prompts and quality prompts that § Autonomy Gate auto-accepts are not escalations — they auto-resolve as usual.
