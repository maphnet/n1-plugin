---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--type <name>] [--no-handoff]"
model: sonnet
---

# N1 Core Orchestrator

**Host vocabulary:** "ask the user" = host question mechanism from HOST ROUTING. "Dispatch persona `<name>`" and "invoke skill `<x>`" follow HOST ROUTING.

**Never dispatch a fork subagent:** dispatches are typed personas or general-purpose subagents with fresh context.

> **BLOCKING DISPATCH REQUIREMENT:** stay foreground — do NOT continue until the worker's result is available. Fabricating completion is a violation. After any dispatch, do not read ahead or poll; if it returns before the result, end the turn with no text and no tool call (detail: `procedures/output-gates.md § Wait Contract`). A notice from a persona you did not dispatch, or a "finished" notice that only says it is waiting or lacks that persona's final status (implementer: DONE or BLOCKED), is not a result: resume the subagent you dispatched by its id via the host message mechanism and idle again; if it already returned its final result, ignore the notice.

Accepts ticket ID or brain dump and orchestrates the full development cycle through N1 personas.

## N1_HOME Resolution

Run before any config or memory access:

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] || echo N1_NOT_CONFIGURED
```

Config: read keys via `n1_*_val` helpers; never cat config.json. Memory: `$N1_HOME/memory/<ID>/`.

**Prerequisites:** `N1_NOT_CONFIGURED` → offer `/n1:n1-init`. **Model Resolution:** dispatches use `n1_resolve_agent <agent-name> [context]`; pass its model (first tab-separated field) to the spawn.

## Procedures (read on demand)

Telemetry Init: `procedures/telemetry.md` | Input Parsing: `procedures/input-parsing.md` | Workspace Isolation: `procedures/workspace-isolation.md` | Resume: `procedures/resume.md` | Output Gates: `procedures/output-gates.md` | Autonomy & Headless: `procedures/autonomy-headless.md` | Rules Injection: `procedures/rules-injection.md` | Cross-Repo: `procedures/cross-repo.md` | Error Recovery: `procedures/error-recovery.md` | Finalize Memory: `procedures/finalize.md`

## Startup Sequence

1. `procedures/telemetry.md` — init telemetry.
2. `procedures/input-parsing.md` — parse input.
3. `procedures/resume.md` — check for existing run; resume or fresh start.
4. Workspace: `procedures/workspace-isolation.md § Workspace Decision` runs on resume or at the end of `steps/ticket.md`, never before `<ID>` is final.

## Pipeline Steps

Step 3 runs autonomously (brainstormer, auto-confirmed acceptance gate). Gate 2 pauses for plan approval when `requirePlanApproval` is enabled, never under `N1_HEADLESS=1`.

**Ticket watch:** before Step 10 (PR creation) run `source ~/.n1/preamble.sh; source "$N1_ROOT/lib/ticket-watch.sh"; n1_tw_check_http "$ID"`. No output: continue without reading the procedure. Any output, an error or a timeout: read `procedures/ticket-watch.md § Check` and act on that output as it says (do not re-run the call).

**Run each step file in order:** read and follow it; never do a step inline or replace its persona dispatch with your own work (simple-path skips only 3, 4, 4b). **Transition turn:** issue in ONE turn, in parallel, the prior step's end block, the ticket-watch Check when due, and the read of the next step file (only when no gate or tier decision in the prior step picks it); act on Check output before running the next step's opening snippet.

| Step | File | Notes |
|------|------|-------|
| 1. REQUIREMENTS ANALYSIS | `steps/ticket.md` | moveStatus → In Progress; assign to creator if configured and unassigned; addToSprint if configured |
| 2. ANALYSIS | `steps/analysis.md` | |
| Simple-Path Routing | — | `n1_read_context`; if `SIMPLE_PATH=true`: skip steps 3, 4, 4b, Gate 2 — jump to Step 5 |
| 3. BRAINSTORM | `steps/brainstorm.md` | autonomous; skipped on simple-path |
| 3b. INVESTIGATION DELIVERABLE | `steps/investigation-deliverable.md` | investigation mode only; terminates pipeline |
| Planning Need Routing | — | `plan` → Step 4; `direct` → Step 5 |
| 4. PLAN | `steps/plan.md` | plan path only; skipped on simple-path |
| 4b. PLAN REVIEW | `steps/plan-review.md` | skipped on simple-path |
| Gate 2 | — | emit Gate 2; if `n1_plan_approval_required`: await user approval |
| 5. IMPLEMENT | `steps/implementation.md` | emit `<ID> · implementing — <N> files` |
| 5b. RUNTIME CROSS-REPO | `procedures/cross-repo.md §5b` | |
| 6. QA | `steps/qa.md` | |
| 7. REVIEW | `steps/review.md` | references `review-core.md`, `ledger.md` |
| 8. FIX (if FAIL or soft pass) | `steps/fix.md` | |
| 9. LOCAL TESTING | `steps/local-testing.md` | conditional |
| 10. PR CREATION | `steps/pr.md` | |
| 11. CI WATCH | `steps/ci.md` | conditional |
| 11b. FINISH WORK | `steps/finish.md` | conditional |
| 12. FINALIZE MEMORY | `procedures/finalize.md` | |
