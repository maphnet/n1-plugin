---
name: n1-estimate
description: "Estimate an existing ticket or task. Runs analysis pipeline then writes complexity tier and delivery time to tracker. Usage: /n1:n1-estimate TRID-510 or /n1:n1-estimate need CSV export for users"
argument-hint: "<ticket-id or task description>"
model: sonnet
effort: low
---

# N1 Estimation

## Overview

Estimate task complexity and delivery time for a ticket or task description. Runs the analysis pipeline (ticket read → codebase analysis → brainstorm) to build context, then classifies complexity and maps to a time estimate. Writes results to the tracker (if configured and enabled) or outputs to the user.

**Announce at start:** "I'm using the n1-estimate skill to estimate this task."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Prerequisites

The N1_HOME Resolution above handles the "not configured" case. If N1_HOME was not resolvable, the skill has already warned the user and stopped.

**Gate check:** Read `$N1_HOME/config.json` → check `estimation.enabled`.
- If `estimation.enabled` is not `true`: Tell the user: "Estimation is not enabled. Run `/n1:n1-init` to configure it, or set `estimation.enabled: true` in `$N1_HOME/config.json`." **STOP.**

## Input Parsing

Same as n1-start — the user provides one of:
- **Ticket ID** — matches the tracker prefix from config (e.g., `TRID-510`, `PROJ-42`)
- **File path** — a path to a file containing requirements
- **Brain dump** — free-text description of what needs to be built

### Detect input type:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
TYPE=$(n1_detect_input_type "<user-input>" "$N1_HOME/config.json")
```

Returns `ticket`, `file`, or `braindump`. If the helper returns `error-tracker`, treat as `braindump` (error tracker URLs are not supported in n1-estimate).

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

Returns the config override if set, otherwise the agent's frontmatter default.

## Memory

Write to `$N1_HOME/memory/$ID/` as usual:
- **Ticket mode:** `<ID>` is the ticket ID
- **File mode:** `<ID>` is a filename slug
- **Brain dump:** `<ID>` is a description slug

If `$N1_HOME/memory/$ID/` already has `ticket.md`, `analysis.md`, and `brainstorm.md` from a prior run, reuse them — skip to the estimation step directly. This avoids duplicate work when the user runs n1-estimate before n1-start.

**No working branch creation.** This is a read-only analysis — do not create or switch branches.

**No status transitions.** Do not move the ticket status in the tracker.

## Pipeline

### 1. REQUIREMENTS ANALYSIS

**Spawn agent:** product-analyst

Same as n1-start Step 1, with these differences:
- **No working branch creation** — skip the Ensure Working Branch procedure
- **No tracker ticket creation** — for brain dump/file modes, do NOT prompt to create a ticket. Use the slug as `<ID>` directly.
- **No status transition** — do not move ticket to "In Progress"
- **Enrichment:** still runs if eligible (same gating as n1-start) — estimation benefits from a well-structured description
- **Output-path directive** (include in spawn instructions): "Write your full structured output (your standard Output Format) to `ticketMdPath` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
  ```
  tier: <simple|standard|complex>
  title: <ticket title>
  ambiguities: <count of ambiguity items, 0 if none>
  ```
  Do NOT return the full report."

After agent returns:
- The agent wrote `$N1_HOME/memory/$ID/ticket.md` itself. Verify it:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
  n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md
  ```
  If missing/empty (agent failed to write), write the returned compact block to `ticket.md` as a fallback and note the gap in overview's `## Key Decisions`: "product-analyst failed to write ticket.md; stub written from compact return -- downstream context is degraded."
- Create initial `overview.md` (same template as n1-start, but without working branch info)

### 2. ANALYSIS

**Spawn agent:** solution-architect

Same as n1-start Step 2. After the agent returns:
- Write output to `$N1_HOME/memory/$ID/analysis.md`

### 3. BRAINSTORM

Read and follow the autonomous brainstormer at `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/autonomous-brainstorm.md` (steps 1–8 only — skip step 9, the step-result emission, which is for n1-loop step mode). Estimation does not require interactive design exploration — the autonomous brainstormer generates approaches, scores them, and selects autonomously. No Skill invocation, no turn boundary.

The autonomous brainstormer reads `ticket.md` and `analysis.md` from `$N1_HOME/memory/$ID/` and writes the design to `$N1_HOME/memory/$ID/brainstorm.md`.

### 4. ESTIMATE

Run the **Estimation** procedure from n1-start (see n1-start SKILL.md, Estimation section). The context available is: `ticket.md`, `analysis.md`, `brainstorm.md` (no `plan.md` — n1-estimate does not run planning).

After estimation:
- Update overview: `[x] Estimation`, set `step: done`

### 5. OUTPUT

Report the estimate to the user:

```
Estimation complete for <ID>:

**Complexity:** <TIER> (<Full Name>)
**Estimated delivery:** <time>
**Basis:** <one sentence>
```

If tracker writes were performed, append: "Estimate written to tracker."
If tracker writes were skipped (no tracker, writeToTracker false, or MCP failure), append: "Estimate saved to memory only."

**STOP.** Do not continue to implementation, QA, review, or PR.
