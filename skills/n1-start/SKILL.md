---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--branch] [--investigate]"
model: sonnet
---

# N1 Core Orchestrator

Use HOST ROUTING for questions, personas, and skills. Accept ticket ID or brain dump; orchestrate analyst through tech-writer.

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; N1_HOME=$(n1_home)
```

Config is `$N1_HOME/config.json`; memory is `$N1_HOME/memory/<ID>/`. Empty N1_HOME: offer init. Dispatch via `n1_resolve_agent <agent-name> [context] [astra-context]`, split model/effort, and pass both; `n1_resolve_model` is compatibility-only.

## Procedures (read on demand)

Telemetry, input, workspace, resume, gates, autonomy, rules, cross-repo, recovery, finalize: read the matching procedure on demand.

## Startup Sequence

1. telemetry; 2. input; 3. resume/fresh start; 4. workspace (skip investigation or completed resume).

## Pipeline Steps

Brainstorm defaults interactive; Gate 2 awaits configured approval.

| Step | File | Notes |
|------|------|-------|
| 1. REQUIREMENTS ANALYSIS | `steps/ticket.md` | |
| 2. ANALYSIS | `steps/analysis.md` | moveStatus → In Progress |
| Simple-Path Routing | — | `n1_read_context`; if `SIMPLE_PATH=true`: skip steps 3, 4, 4b, Gate 2 — jump to Estimation (if enabled) then Step 5 |
| 3. BRAINSTORM | `steps/brainstorm.md` | interactive unless auto; skipped on simple-path |
| 3b. INVESTIGATION DELIVERABLE | `steps/investigation-deliverable.md` | investigation mode only; terminates pipeline |
| Estimation | `steps/estimation.md` | run after brainstorm (direct) or after plan |
| Planning Need Routing | — | `plan` → Step 4; `direct` → Estimation then Step 5 |
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
