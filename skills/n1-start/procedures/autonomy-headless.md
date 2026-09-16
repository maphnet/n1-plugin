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

Applies whenever the environment variable `N1_HEADLESS` equals `1` (the run was launched by `n1-story-run` or another non-interactive parent). There is no user to answer prompts.

At any point where a step would ask the user or otherwise **wait for the user** (plan checkpoint, acceptance gate fallback, quality-gate exhaustion on security/architecture/public-API findings, brainstorm escalation below margin, error-recovery "report to user"), do this instead:

1. Append to `## Escalations` in `$N1_HOME/memory/$ID/overview.md`:
   `- [headless] <step>: <the exact question or decision that needed a human>, options: <options>`
2. Set frontmatter `step: escalated`:
   ```bash
   N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
   source "$N1_ROOT/lib/frontmatter.sh"
   n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" "step" "escalated"
   ```
3. Run the telemetry failure path from **Error Recovery** (emit `outcome: "failed"` for the current step, merge), clear the active-run pointer, print `HEADLESS ESCALATION: <one line>` and **end the run**. Do not retry, do not continue to later steps.

A later `/n1:n1-start <ID>` in an interactive session resumes at the escalated step and asks the question normally (resume support reads `## Escalations`; on resume with `N1_HEADLESS` unset, reset `step` to the last completed step before continuing).

Mechanical prompts covered by `autonomy.mechanicalPrompts=auto` and quality prompts covered by `qualityEscalations=auto-accept` are not escalations — they auto-resolve as usual.
