---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--branch] [--investigate]"
model: sonnet
---

# N1 Core Orchestrator

**Host vocabulary:** "ask the user" = host question mechanism from HOST ROUTING. "Dispatch persona `<name>`" and "invoke skill `<x>`" follow HOST ROUTING.

Accepts ticket ID or brain dump. Orchestrates full development cycle: product-analyst, solution-architect, developer, qa-engineer, code-reviewer, security-reviewer, tech-writer.

## N1_HOME Resolution

Run at start of every run before any config or memory access:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; N1_HOME=$(n1_home)
```

Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/<ID>/`.

**Prerequisites:** `N1_HOME` empty → tell user N1 not configured, offer `/n1:n1-init`. **Model Resolution:** `n1_resolve_model <agent-name> [context]`.

## Procedures (read on demand)

Telemetry Init: `procedures/telemetry.md` | Input Parsing: `procedures/input-parsing.md` | Workspace Isolation: `procedures/workspace-isolation.md` | Resume: `procedures/resume.md` | Output Gates: `procedures/output-gates.md` | Autonomy & Headless: `procedures/autonomy-headless.md` | Rules Injection: `procedures/rules-injection.md` | Cross-Repo: `procedures/cross-repo.md` | Error Recovery: `procedures/error-recovery.md` | Finalize Memory: `procedures/finalize.md`

## Startup Sequence

1. `procedures/telemetry.md` — init telemetry.
2. `procedures/input-parsing.md` — parse input.
3. `procedures/resume.md` — check for existing run; resume or fresh start.
4. `procedures/workspace-isolation.md` — set up workspace (skip for investigation; skip on resume if done).

## Pipeline Steps

Step 3 is **INTERACTIVE** by default (`autonomy.brainstorm=auto` → headless). Gate 2 pauses for plan approval when `requirePlanApproval` enabled.

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
