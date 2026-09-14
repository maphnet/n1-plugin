---
name: n1-start
description: "Core orchestrator. Start working on a task: /n1:n1-start TRID-510 or /n1:n1-start need CSV export for users. Handles the full cycle: ticket → analysis → brainstorm → plan → implement → QA → review → [local testing] → PR."
argument-hint: "<ticket-id or brain dump> [--branch] [--investigate]"
model: sonnet
---

# N1 Core Orchestrator

## Overview

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from HOST ROUTING (a question tool on Claude Code, a plain numbered-options message on Codex). "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Single entry point for all task work. Accepts a ticket ID or brain dump, then orchestrates the full development cycle using: product-analyst, solution-architect, developer, qa-engineer, code-reviewer, security-reviewer, tech-writer.

## N1_HOME Resolution

Run at the start of every run, before any config or memory access:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/<ID>/`. All telemetry paths use `$N1_HOME/memory/<ID>/telemetry/`.

## Prerequisites

If `N1_HOME` is empty: tell the user N1 is not configured and offer `/n1:n1-init`. Wait; if yes run it then resume, if no STOP. If resolved: continue.

## Model Resolution

When spawning any agent, use the N1_HOME Resolution preamble and call `n1_resolve_model <agent-name> [context]`. Resolution chain: config override > signal-driven triggers > profile step_overrides > agent frontmatter default.

## Procedures (read on demand)

Read the procedure file when a step instructs you to.

| Procedure | File |
|-----------|------|
| Telemetry Init | `procedures/telemetry.md` |
| Input Parsing | `procedures/input-parsing.md` |
| Workspace Isolation | `procedures/workspace-isolation.md` |
| Resume | `procedures/resume.md` |
| Output Gates | `procedures/output-gates.md` |
| Autonomy & Headless | `procedures/autonomy-headless.md` |
| Rules Injection | `procedures/rules-injection.md` |
| Cross-Repo | `procedures/cross-repo.md` |
| Error Recovery | `procedures/error-recovery.md` |
| Finalize Memory | `procedures/finalize.md` |

## Startup Sequence

Before Step 1:
1. Read `procedures/telemetry.md` — initialize telemetry.
2. Read `procedures/input-parsing.md` — parse user input.
3. Read `procedures/resume.md` — check for existing run; if found, resume. Otherwise fresh start.
4. Read `procedures/workspace-isolation.md` — set up workspace (skip for investigation type; skip on resume if already done).

## Pipeline Steps

Step 3 (Brainstorm) is **INTERACTIVE** by default. When `autonomy.brainstorm` is `auto`, the autonomous brainstormer runs headlessly. Gate 2 pauses for plan approval when `requirePlanApproval` is enabled.

### 1. REQUIREMENTS ANALYSIS

Read and follow `<N1_ROOT>/skills/n1-start/steps/ticket.md`.

### 2. ANALYSIS

Read and follow `<N1_ROOT>/skills/n1-start/steps/analysis.md`.

### 3. BRAINSTORM

Read and follow `<N1_ROOT>/skills/n1-start/steps/brainstorm.md`.

### 3b. INVESTIGATION DELIVERABLE (investigation mode only)

Read and follow `<N1_ROOT>/skills/n1-start/steps/investigation-deliverable.md`.

Runs only when `TYPE` is `"investigation"`. After this step the pipeline terminates.

### Estimation

Read and follow `<N1_ROOT>/skills/n1-start/steps/estimation.md`.

### Planning Need Routing

If `TYPE` is `"investigation"`, skip — always go to investigation-deliverable.

Read `planning_need` from brainstorm output:
- `plan` → Step 4 (PLAN)
- `direct` → Run Estimation, then Step 5 (IMPLEMENT)

### 4. PLAN (plan path only)

Read and follow `<N1_ROOT>/skills/n1-start/steps/plan.md`.

### 4b. PLAN REVIEW

Read and follow `<N1_ROOT>/skills/n1-start/steps/plan-review.md`.

### 4c. Estimation (after plan)

Run the Estimation step (see above).

### Gate 2 — Pre-Implementation Brief

Emit Gate 2 (see `procedures/output-gates.md § Gate 2`). Sources: intent from `overview.md ## Key Decisions`, files from `plan.md`, risk from `analysis.md` signals.

Check `n1_plan_approval_required` (N1_HOME preamble + `n1_plan_approval_required`). If `true`: after Gate 2, ask user to approve the plan; wait for approval (headless: apply `procedures/autonomy-headless.md § Headless Guard`); on approval write frontmatter `plan_approved: true`.

### 5. IMPLEMENT

Emit one liveness line: `<ID> · implementing — <N> files`. Then read and follow `<N1_ROOT>/skills/n1-start/steps/implementation.md`.

### 5b. RUNTIME CROSS-REPO DETECTION

Read `<N1_ROOT>/skills/n1-start/procedures/cross-repo.md` and follow **§5b Runtime Cross-Repo Detection**.

### 6. QA

Read and follow `<N1_ROOT>/skills/n1-start/steps/qa.md`.

### 7. REVIEW

Read and follow `<N1_ROOT>/skills/n1-start/steps/review.md`. That step references `<N1_ROOT>/skills/n1-start/review-core.md` for diff-surface classification and reviewer scope rules.

Autonomous decisions are recorded per `skills/n1-start/ledger.md`.

### 7b. REVIEW CROSS-REPO TELEMETRY

Read `<N1_ROOT>/skills/n1-start/procedures/cross-repo.md` and follow **§7b Review Cross-Repo Telemetry**.

### 8. FIX (if review failed)

Read and follow `<N1_ROOT>/skills/n1-start/steps/fix.md`.

### 9. LOCAL TESTING (conditional)

Read and follow `<N1_ROOT>/skills/n1-start/steps/local-testing.md`.

### 10. PR CREATION

Read and follow `<N1_ROOT>/skills/n1-start/steps/pr.md`.

### 11. CI WATCH (conditional)

Read and follow `<N1_ROOT>/skills/n1-start/steps/ci.md`.

### 11b. FINISH WORK (conditional)

Read and follow `<N1_ROOT>/skills/n1-start/steps/finish.md`.

### 11c. INVESTIGATION DELIVERABLE (conditional)

Read and follow `<N1_ROOT>/skills/n1-start/steps/investigation-deliverable.md`.

### 12. FINALIZE MEMORY

Read `<N1_ROOT>/skills/n1-start/procedures/finalize.md` and follow the **Finalize Memory** procedure.
