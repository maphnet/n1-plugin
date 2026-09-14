# Procedure: Error Recovery

## Error Recovery

Classify failure:
- **Transient** (tracker/MCP timeout, rate-limit, agent-spawn hiccup, network blip) → retry once or twice before escalating.
- **Terminal or ambiguous** (logic error, repeated failure, unresolvable blocker):
  1. Note in `overview.md ## Escalations`.
  2. **Telemetry:** emit final step event with `outcome: "failed"` and run merge script.
  3. Report to user: 20 words per line — what failed and where. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.
  4. On next `/n1:n1-start <ID>`: resume from last successful step.

## Context Management

This orchestrator is a **lightweight controller**: delegates heavy work to agents, loads only dependency files per step, writes to memory after each step, never accumulates full history.

**Memory hygiene:** compact files that grow large (long `analysis.md`, multi-cycle `review.md`) before next step reads them — verbose stale notes cause context poisoning.

**Resume:** treat files-changed lists and test results as hints; re-derive from `git` and test suite rather than trusting stale markdown.
