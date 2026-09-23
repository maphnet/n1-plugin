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

Applies whenever the environment variable `N1_HEADLESS` equals `1` (the run was launched by `n1-queue` or another non-interactive parent). There is no user to answer prompts.

At any point where a step would ask the user or otherwise **wait for the user**, classify the prompt against the **stop list** before escalating.

**Stop list:** the categories in `n1_escalation_val 'alwaysAskOn'` (default: `security`, `architecture`, `public-api`) plus the release confirmation gate (always unconditional).

**If the prompt is NOT on the stop list AND the step has a recommended option** (the option marked "(Recommended)" or listed first as default): take the recommended option silently. Log it:

```bash
source "$N1_ROOT/lib/preamble.sh"
OVERVIEW="$N1_HOME/memory/$ID/overview.md"
grep -q '^## Decision Ledger' "$OVERVIEW" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OVERVIEW"
printf '| %s | headless | %s | [auto] | %s | %s | %s | headless: not on stop list | --- |\n' "$STEP" "$TIER" "$QUESTION" "$RECOMMENDED" "$ALTERNATIVES" >> "$OVERVIEW"
```

Then continue the run — do not escalate, do not end.

**If the prompt IS on the stop list, is the release gate, or has no recommended option**, escalate:

1. Append to `## Escalations` in `$N1_HOME/memory/$ID/overview.md`:
   `- [headless] <step>: <the exact question or decision that needed a human>, options: <options>`
2. **Tell the tracker** (best-effort — a failure here never blocks the escalation):
   a. If `n1_config_val '.tracker.statuses.blocked'` is set, move the ticket via `mcp__<tracker.mcp>__<operations.moveStatus>` (Jira: get transition ID via `getTransitions` first). Do not overwrite the existing `original_status` frontmatter.
   b. Post a comment via `mcp__<tracker.mcp>__<operations.addComment>`:
      ```
      N1 [headless] <step>: <one-line reason>
      <question(s) and options, one per line>
      Memory: $N1_HOME/memory/<ID>/
      Resume: /n1:n1-start <ID>
      n1-esc:<ID>:<step>
      ```
      The last line is an idempotency marker. Before posting on YouTrack, fetch comments via `mcp__<tracker.mcp>__<operations.getComments>` and skip if any comment contains `n1-esc:<ID>:<step>`. On Jira, skip the duplicate check (no listed getComments op) and post directly.
3. Set frontmatter `step: escalated`:
   ```bash
   source "$N1_ROOT/lib/preamble.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "escalated"
   ```
4. Run the telemetry failure path from **Error Recovery** (emit `outcome: "failed"` for the current step, merge), clear the active-run pointer, print `HEADLESS ESCALATION: <one line>` and **end the run**. Do not retry, do not continue to later steps.

A later `/n1:n1-start <ID>` in an interactive session resumes at the escalated step and asks the question normally (resume support reads `## Escalations`; on resume with `N1_HEADLESS` unset, reset `step` to the last completed step before continuing).

Mechanical prompts covered by `autonomy.mechanicalPrompts=auto` and quality prompts covered by `qualityEscalations=auto-accept` are not escalations — they auto-resolve as usual.
