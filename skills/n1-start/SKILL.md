---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--investigate]"
model: sonnet
---

# N1 Core Orchestrator

**Host vocabulary:** "ask the user" = host question mechanism from HOST ROUTING. "Dispatch persona `<name>`" and "invoke skill `<x>`" follow HOST ROUTING.

**Never dispatch a fork subagent:** dispatches are typed personas or general-purpose subagents with fresh context.

> **BLOCKING DISPATCH REQUIREMENT:** stay foreground — do NOT continue until the worker's result is available. Fabricating completion is a violation.

Accepts ticket ID or brain dump and orchestrates the full development cycle through N1 personas.

## N1_HOME Resolution

Run at start of every run before any config or memory access:

```bash
source ~/.n1/preamble.sh
```

Config: read keys via `n1_*_val` helpers; never cat config.json. Memory: `$N1_HOME/memory/<ID>/`.

**Prerequisites:** `N1_HOME` empty → tell user N1 not configured, offer `/n1:n1-init`. **Model Resolution:** dispatches use `n1_resolve_agent <agent-name> [context]`; pass its model (first tab-separated field) to the spawn.

## Procedures (read on demand)

Telemetry Init: `procedures/telemetry.md` | Input Parsing: `procedures/input-parsing.md` | Workspace Isolation: `procedures/workspace-isolation.md` | Resume: `procedures/resume.md` | Output Gates: `procedures/output-gates.md` | Autonomy & Headless: `procedures/autonomy-headless.md` | Rules Injection: `procedures/rules-injection.md` | Cross-Repo: `procedures/cross-repo.md` | Error Recovery: `procedures/error-recovery.md` | Finalize Memory: `procedures/finalize.md`

## Startup Sequence

1. `procedures/telemetry.md` — init telemetry.
2. `procedures/input-parsing.md` — parse input.
3. `procedures/resume.md` — check for existing run; resume or fresh start.
4. `procedures/workspace-isolation.md` — set up workspace (skip for investigation; skip on resume if done).

## Pipeline Steps

Step 3 is **INTERACTIVE** by default (`autonomy.brainstorm=auto` → headless). Gate 2 pauses for plan approval when `requirePlanApproval` enabled.

**Ticket watch:** run `procedures/ticket-watch.md § Check` before Steps 5, 6, 10 and 11b.

| Step | File | Notes |
|------|------|-------|
| 1. REQUIREMENTS ANALYSIS | `steps/ticket.md` | |
| 2. ANALYSIS | `steps/analysis.md` | moveStatus → In Progress; assign to creator if configured and unassigned; addToSprint if configured |
| Simple-Path Routing | — | `n1_read_context`; if `SIMPLE_PATH=true`: skip steps 3, 4, 4b, Gate 2 — jump to Step 5 |
| 3. BRAINSTORM | `steps/brainstorm.md` | interactive unless auto; skipped on simple-path |
| 3b. INVESTIGATION DELIVERABLE | `steps/investigation-deliverable.md` | investigation mode only; terminates pipeline |
| Planning Need Routing | — | `plan` → Step 4; `direct` → Step 5 |
| 4. PLAN | `steps/plan.md` | plan path only; skipped on simple-path |
| 4b. PLAN REVIEW | `steps/plan-review.md` | skipped on simple-path |
| Gate 2 | — | emit Gate 2; if `n1_plan_approval_required`: await user approval |
| 5. IMPLEMENT | `steps/implementation.md` | emit `<ID> · implementing — <N> files` |
| 5b. RUNTIME CROSS-REPO | `procedures/cross-repo.md §5b` | |
| 6. QA | `steps/qa.md` | |
| 7. REVIEW | `steps/review.md` | references `review-core.md`, `ledger.md` |
| 7b. REVIEW CROSS-REPO TELEMETRY | `procedures/cross-repo.md §7b` | |
| 8. FIX (if FAIL) | `steps/fix.md` | |
| 9. LOCAL TESTING | `steps/local-testing.md` | conditional |
| 10. PR CREATION | `steps/pr.md` | |
| 11. CI WATCH | `steps/ci.md` | conditional |
| 11b. FINISH WORK | `steps/finish.md` | conditional |
| 12. FINALIZE MEMORY | `procedures/finalize.md` | |
