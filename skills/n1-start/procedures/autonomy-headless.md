# Procedure: Autonomy Gate and Headless Guard

Covers the qualityEscalations autonomy gate and the headless guard for non-interactive runs.

## Autonomy Gate (qualityEscalations)

When a quality step has findings that the user would normally be prompted about, check the autonomy policy first.

**Parameters:** `{step}`, `{action}` (what auto-accept does, e.g. "accept remaining findings"), `{ledger_context}` (summary for the Decision Ledger row)

```bash
QE=$(n1_autonomy_val 'qualityEscalations')
```

**If `QE` is `auto-accept`** AND the findings do NOT involve security, architecture, or public API changes: take `{action}` silently. Append a Decision Ledger row to overview.md:

`| {step} | quality | A | [auto] | {ledger_context} | {action} | Prompt user | qualityEscalations=auto-accept | --- |`

**If `QE` is `block`** (default) or the findings involve security/architecture/public API: show the interactive prompt as defined by the step file.

**Headless:** under `N1_HEADLESS=1`, apply § Headless Guard below instead of prompting.

## Headless Guard

Applies whenever the environment variable `N1_HEADLESS` equals `1` (the run was launched by `n1-queue` or another non-interactive parent). There is no user to answer prompts directly.

When `N1_UNATTENDED` also equals `ask` (set for Claude Code queue children), an escalation pauses and asks the user instead of ending the run — see the ask-mode branch below. Any other headless run (Codex / `-p` children, or `N1_HEADLESS=1` with `N1_UNATTENDED` unset) keeps the escalate-and-exit path unchanged.

At any point where a step would ask the user or otherwise **wait for the user**, classify the prompt against the **stop list** before escalating.

**Stop list:** the categories in `n1_escalation_val 'alwaysAskOn'` (default: `security`, `architecture`, `public-api`) plus the release confirmation gate (always unconditional).

**If the prompt is NOT on the stop list AND the step has a recommended option** (the option marked "(Recommended)" or listed first as default): take the recommended option silently. Log it:

```bash
source ~/.n1/preamble.sh
OVERVIEW="$N1_HOME/memory/$ID/overview.md"
grep -q '^## Decision Ledger' "$OVERVIEW" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OVERVIEW"
printf '| %s | headless | %s | [auto] | %s | %s | %s | headless: not on stop list | --- |\n' "$STEP" "$TIER" "$QUESTION" "$RECOMMENDED" "$ALTERNATIVES" >> "$OVERVIEW"
```

Then continue the run — do not escalate, do not end.

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
   source ~/.n1/preamble.sh
   printf -- '- [headless] %s: %s, options: %s (blocked-move: %s)\n' "$STEP" "$QUESTION" "$OPTIONS" "$MOVE_OUTCOME" >> "$N1_HOME/memory/$ID/overview.md"
   ```
3. Post a comment via `mcp__<tracker.mcp>__<operations.addComment>` (best-effort — a failure here never blocks the escalation):
   ```
   N1 [headless] <step>: <one-line reason>
   <question(s) and options, one per line>
   Memory: $N1_HOME/memory/<ID>/
   Resume: /n1:n1-start <ID>
   n1-esc:<ID>:<step>
   ```
   The last line is an idempotency marker. Before posting on YouTrack, fetch comments via `mcp__<tracker.mcp>__<operations.getComments>` and skip if any comment contains `n1-esc:<ID>:<step>`. On Jira, skip the duplicate check (no listed getComments op) and post directly.
4. Branch on `N1_UNATTENDED`:

   **Not `ask`** (Codex / `-p` children, or `N1_HEADLESS=1` alone) — escalate-and-exit, unchanged:
   a. Set frontmatter `step: escalated`:
      ```bash
      source ~/.n1/preamble.sh
      n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "escalated"
      ```
   b. Run the telemetry failure path from **Error Recovery** (emit `outcome: "failed"` for the current step, merge), clear the active-run pointer, print `HEADLESS ESCALATION: <one line>` and **end the run**. Do not retry, do not continue to later steps.

   **`ask`** (Claude Code queue children) — ask-mode, pause instead of ending:
   a. Ask the user with a self-contained question (it is read from an agent-view summary without conversation context): ticket ID, step, the decision, each option (marking the recommended one), and a final explicit "Stop this ticket" option to abandon the escalation.
   b. The run blocks on that question. No frontmatter, ledger, or file write happens while waiting.
   c. On answer **"Stop this ticket"**: run the same exit steps as the non-ask branch above (`step: escalated`, telemetry failure path, end run). The ticket stays in the blocked status; a human re-runs `/n1:n1-start <ID>` manually later.
   d. On any other answer: move the ticket via `moveStatus` to `n1_config_val '.tracker.statuses.inProgress'` (skip the move if that status is unset; do not touch `original_status` frontmatter). Append a Decision Ledger row:
      ```bash
      source ~/.n1/preamble.sh
      OVERVIEW="$N1_HOME/memory/$ID/overview.md"
      grep -q '^## Decision Ledger' "$OVERVIEW" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OVERVIEW"
      printf '| %s | headless | %s | [asked] | %s | %s | %s | headless: ask-mode answer | --- |\n' "$STEP" "$TIER" "$QUESTION" "$ANSWER" "$ALTERNATIVES" >> "$OVERVIEW"
      ```
      Then continue the current step with the chosen answer. `step:` frontmatter is unchanged, so this is a normal in-step continuation, not a resume.

A later `/n1:n1-start <ID>` in an interactive session resumes at the escalated step and asks the question normally (resume support reads `## Escalations`; on resume with `N1_HEADLESS` unset, reset `step` to the last completed step before continuing).

Mechanical prompts covered by `autonomy.mechanicalPrompts=auto` and quality prompts covered by `qualityEscalations=auto-accept` are not escalations — they auto-resolve as usual.
