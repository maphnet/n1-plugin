# N1 (No-One)

AI-driven development orchestrator for Claude Code. No one writes the code.

N1 is a Claude Code plugin that orchestrates the full development cycle using 9 specialized agent personas and [Superpowers](https://github.com/obra/superpowers) sub-skills. Agents handle autonomous work (analysis, QA, review, fixes, PR content); Superpowers handles interactive steps (brainstorming, planning, implementation dispatch). Adds tracker integration, per-ticket memory, adaptive workflow routing, confidence-based escalation, parallel security review, and a mandatory review loop.

## Requirements

- [Claude Code](https://claude.ai/code) 2.1+
- [Superpowers](https://github.com/obra/superpowers) plugin ^5.0
- `git` and `gh` (GitHub CLI) on PATH
- Optional: Jira (Atlassian MCP) or YouTrack MCP for tracker integration
- Optional: Sentry MCP for error-tracking integration

## Installation

Add the marketplace and install:

```
/plugin marketplace add maphnet/n1-plugin
/plugin install n1@n1
```

Then enable auto-update: `/plugin` → Marketplaces → n1 → Auto-update.

For local development:

```bash
claude --plugin-dir ~/dev/n1-plugin
```

## Quick Start

```
# 1. Set up N1 for your project
/n1:n1-init

# 2. Start working on a task
/n1:n1-start TRID-510              # from a tracker ticket
/n1:n1-start add CSV export users  # from a brain dump
/n1:n1-start https://myorg.sentry.io/issues/12345  # from a Sentry error

# 3. Or use skills standalone
/n1:n1-estimate TRID-510           # estimate a ticket
/n1:n1-review                      # review current branch (fix loop)
/n1:n1-review #340                 # advisory review of a PR
/n1:n1-pr                          # finalize branch: docs, push, create or skip PR
/n1:n1-finish                      # verify/merge PR, watch deploy, close ticket
```

## Skills

### `/n1:n1-start` — Core Orchestrator

Single entry point for all task work. Full pipeline:

```
Input (ticket or brain dump)
  → Ticket read (product-analyst agent)
  → Codebase analysis (solution-architect agent)
  → Brainstorm (superpowers:brainstorming, with architect's analysis)
  → Plan (planner agent → superpowers:writing-plans) — if complex
  → Implement (superpowers:SDD + developer persona)
  → QA (qa-engineer agent)
  → Review (code-reviewer + security-reviewer agents, parallel)
  → Fix loop (developer agent, if needed)
  → PR (n1:n1-pr → tech-writer agent)
  → Tracker update
  → Finish (n1:n1-finish, if finishWork.enabled) — merge verify, deploy watch, ticket close
```

- **Agent personas:** 9 specialized agents with scoped tools and configurable models
- **Parallel security review:** code-reviewer and security-reviewer run simultaneously
- **Adaptive routing:** simple tasks skip the plan step
- **Resume support:** interrupt anytime, `/n1:n1-start TRID-510` picks up where you left off
- **Confidence-based escalation:** low confidence + high blast radius = stop and ask
- **Step mode:** `--step <name>` runs a single pipeline step and exits with a structured result

### `/n1:n1-review` — Code Review

Two modes:

| Mode | Trigger | Behavior |
|------|---------|----------|
| Review Loop | No args, on feature branch | code-reviewer + security-reviewer (parallel) → developer fixes → repeat until clean |
| Advisory | `/n1:n1-review #340` | code-reviewer report only, no fixes |

### `/n1:n1-pr` — Pull Request Creation

Spawns tech-writer agent for doc updates and PR content, pushes, creates PR via `gh` (or exits immediately when `prMode: "skip"`), and updates the tracker.

### `/n1:n1-finish` — Finish Work

Completes the cycle after PR/CI: verifies the PR is merged (or merges it when `finishWork.mergeOnFinish` is enabled), optionally watches the deployment workflow triggered by the merge commit, moves the tracker ticket to Done, and cleans up the branch/worktree. The ticket is closed only when the code is actually merged — never on green-CI-but-open.

- Standalone and idempotent — works with or without the `finishWork.enabled` pipeline gate
- Projects with `prMode: "skip"` get a local merge into the default branch (no push)
- Configure via `/n1:n1-init` or the `finishWork` block in `~/.n1/<project>/config.json`

```
/n1:n1-finish            # verify/merge current branch's PR, close ticket
/n1:n1-finish TRID-510   # target a specific ticket
/n1:n1-finish #123       # target a specific PR number
```

### `/n1:n1-init` — Project Setup

Interactive wizard:

1. Analyzes your repo (stack, docker, test runner, linter)
2. Enriches CLAUDE.md with detected conventions
3. Configures tracker (Jira / YouTrack / None)
4. Sets up git defaults and review policy
5. Detects and configures error tracking (Sentry)
6. Configures estimation (off by default — complexity tier → delivery time)
7. Configures agent models (defaults or custom per-agent)
8. Creates `~/.n1/<project>/` state directory and sets `git config n1.home` (v1 projects: offers migration from `.n1/`)
9. Adds `.claude/worktrees/` to `.gitignore`

### `/n1:n1-estimate` — Task Estimation

Estimates task complexity and delivery time. Runs the analysis pipeline (ticket read → codebase analysis → brainstorm), classifies complexity into a tier (XS–XL), and maps to a time estimate.

- Writes estimate to tracker ticket (description + time field) when enabled
- Reuses existing analysis if the ticket was previously analyzed
- No branch creation or status transitions — read-only analysis
- Configure via `/n1:n1-init` or set `estimation.enabled: true` in `~/.n1/<project>/config.json`

### `/n1:n1-clean` — Worktree Cleanup

Removes the git worktree for a ticket after work is done or abandoned. Use when a worktree was not automatically cleaned up by `n1-pr` (e.g., when PR was skipped or the session was interrupted).

```
/n1:n1-clean TRID-510   # remove worktree for TRID-510
/n1:n1-clean            # remove worktree for the current branch's ticket
```

## Tracker Support

| Tracker | MCP Server | Status |
|---------|------------|--------|
| Jira | `plugin_atlassian_atlassian` | Supported |
| YouTrack | `youtrack` | Supported |
| None | — | Works without tracker |

Tracker routing is config-driven via `~/.n1/<project>/config.json` (discovered via `git config n1.home`) — all MCP tool names are mapped through operations presets populated by `n1-init`.

Created tickets can optionally be tagged with a service name. When `ticketTagging.enabled` is set (off by default; configured by `n1-init`), N1-created tickets get a `{service} | <title>` summary prefix and a `**Service:** <service>` line in the description.

Tickets N1 creates are auto-assigned to you (the authenticated tracker user) by default. Set `tracker.assignToCreator` to `false` (or answer No during `n1-init`) to disable. Applies to created tickets only; never changes the assignee of existing tickets.

## Error Tracking Support

| Provider | MCP Server | Status |
|----------|------------|--------|
| Sentry | `sentry` (official MCP) | Supported |

Error tracking is optional and independent of tracker integration. When configured via `n1-init`, N1 accepts error-tracker issue URLs as input to `n1-start`. The product-analyst fetches structured error data (stack trace, breadcrumbs, event frequency, AI root-cause analysis) and the solution-architect searches for related issues during codebase analysis.

Sentry issues can optionally be promoted to tracker tickets (Jira/YouTrack) during the pipeline, or worked standalone with `sentry-<issueId>` as the working identifier.

## Estimation

Optional complexity classification that maps tasks to delivery time estimates. Off by default — enable via `n1-init` or set `estimation.enabled: true` in `~/.n1/<project>/config.json`.

| Tier | Default Time | Characteristics |
|------|-------------|-----------------|
| XS | 30m | Config change, typo, single-line fix |
| S | 2h | Single file, clear scope, no migrations |
| M | 6h | 2-5 files, may need tests, straightforward |
| L | 2d | Multiple files, migrations, new tests |
| XL | 5d | Cross-cutting, architectural, multi-subsystem |

Times represent total delivery (including QA/review), not just coding. Default mapping is overridable per-project via `estimation.mapping` in config.

When enabled, estimation runs automatically in the `n1-start` pipeline (after plan for complex tasks, after brainstorm for simple tasks) and writes to the tracker's time field (Jira `originalEstimate`, YouTrack `Estimation`). Use `/n1:n1-estimate` standalone to estimate without running the full pipeline.

## How It Works

N1 is a **lightweight controller** (~5-10K tokens) that uses a hybrid delegation model: 9 specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while Superpowers sub-skills handle interactive steps (brainstorming, planning, implementation dispatch via SDD). Each agent gets fresh context with scoped tools.

### Agent Personas

| Agent | Default Model | Role |
|-------|---------------|------|
| product-analyst | sonnet | Ticket distillation and requirements extraction |
| solution-architect | opus | Codebase analysis and architecture assessment |
| planner | opus | Isolated implementation-plan writing |
| developer | opus | Implementation and review fix cycles |
| code-reviewer | opus | Adversarial code quality review |
| security-reviewer | opus | Security vulnerability review (OWASP, CWE) |
| qa-engineer | sonnet | Test design and implementation |
| tech-writer | sonnet | PR content generation |

Models are configurable per-project via `models` section in `~/.n1/<project>/config.json`.

### Per-Ticket Memory

Per-ticket memory lives in `~/.n1/<project>/memory/<ticket-id>/` (externalized, never inside the project tree) with semantic-named files and an explicit dependency map:

| Step | Reads | Writes |
|------|-------|--------|
| ticket | — | `ticket.md` |
| analysis | `ticket.md` | `analysis.md` |
| brainstorm | `ticket.md`, `analysis.md` | `brainstorm.md` |
| plan | `ticket.md`, `brainstorm.md`, `analysis.md` | `plan.md` |
| estimation | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` (if exists) | `overview.md` |
| implementation | `brainstorm.md`, `plan.md` | `implementation.md` |
| qa | `ticket.md`, `implementation.md`, `plan.md` | `qa.md` |
| review | `ticket.md`, `brainstorm.md`, `implementation.md`, `qa.md` | `review.md` |
| pr | `overview.md`, `review.md`, `qa.md` | — |

The `~/.n1/<project>/` directory lives outside your project tree — tool state never gets committed to your repo. N1 uses git worktrees (`<project>/.claude/worktrees/<ID>/`) for isolation; only `.claude/worktrees/` needs to be gitignored (handled by `n1-init`).

Throwaway investigative tests and benchmarks (one-off probes that answer a question rather than verify shipped code) are written under `~/.n1/<project>/` too — they never land in your repo's test suite. Real unit/integration/e2e tests that cover the implemented feature are committed to the repo as usual.

## Escalation Model

**Fixed checkpoints (always):**
- After PR creation — Tech Lead reviews

**Confidence-based (during implementation):**
- Low confidence + High blast radius → stop and ask
- Low confidence + Low blast radius → proceed, note decision
- High confidence → full autonomy

**Always escalates for:** security changes, new architecture patterns, public API changes.

## Troubleshooting

**"API Error: Usage credits required for 1M context" when invoking an N1 skill.** N1 skills pin
a session model via frontmatter (`model: sonnet` on most skills) to keep orchestration cheap. If
your saved `sonnet` preference resolves to the Sonnet 4.6 **1M-context** variant, that variant
requires usage credits on every plan (including Max) and the session blocks immediately. Fix:
set `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` in your environment (removes 1M variants entirely), or
run `/model` and select standard-context Sonnet so the alias stops resolving to the 1M variant.

## License

MIT
