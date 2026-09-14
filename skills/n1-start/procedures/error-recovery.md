# Procedure: Error Recovery and Context Management

Covers step failure classification, retry strategy, and orchestrator context hygiene.

## Error Recovery

If any step fails, first classify the failure:

- **Transient** (tracker/MCP timeout, `gh` rate-limit, agent-spawn hiccup, network blip) → retry once or twice with brief backoff before escalating.
- **Terminal or ambiguous** (logic error, repeated failure after retry, an unresolvable blocker) → do not retry blindly:
  1. Note the failure in overview.md under `## Escalations`
  2. **Telemetry (if enabled):** Before escalating, emit a final step event with `outcome: "failed"` for the current step, and run the merge script. This ensures interrupted runs produce partial but valid telemetry records.
  3. Report to the user with context (budget: 20 words per line — state what failed and where; do not narrate diagnosis steps). **Headless:** under `N1_HEADLESS=1`, apply `procedures/autonomy-headless.md § Headless Guard` instead of prompting.
  4. On next `/n1:n1-start <ID>`, resume support picks up from the last successful step

## Context Management

This orchestrator is a **lightweight controller**. It:
- Delegates all heavy work to specialized agent personas (each gets fresh context)
- Loads only the dependency files needed for the current step
- Writes output to memory files after each step (explicit handoff)
- Never accumulates full history in its own context

### Memory hygiene

- **Soft size budget per memory file.** If a file grows large (a long bug investigation in `analysis.md`, a multi-cycle `review.md`), compact it to its high-signal conclusions before the next step reads it — verbose, stale notes are the raw material of context poisoning on long or resumed runs.
- **Re-derive volatile facts on resume.** Treat files-changed lists and test results stored in memory as hints, not ground truth: on resume, re-derive them from `git` and the test suite rather than trusting potentially stale markdown.
