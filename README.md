# N1 (No-One)

AI-driven development orchestrator for Claude Code. No one writes the code.

N1 is a Claude Code plugin that orchestrates the full development cycle using 12 specialized agent personas and native skills. Agents handle autonomous work (analysis, QA, review, fixes, PR content); native skills handle interactive steps (brainstorming, planning, implementation dispatch). Adds tracker integration, per-ticket memory, adaptive workflow routing, confidence-based escalation, parallel security review, and a mandatory review loop.

## Requirements

- [Claude Code](https://claude.ai/code) 2.1+
- `git`, `gh` (GitHub CLI), `jq`, and `python3` on PATH
- Optional: Jira (Atlassian MCP) or YouTrack MCP for tracker integration
- Optional: Sentry MCP for error-tracking integration

## Installation

### Claude Code

```
/plugin marketplace add maphnet/n1-plugin
/plugin install n1@n1
```

Then enable auto-update: `/plugin` → Marketplaces → n1 → Auto-update.

For local development:

```bash
claude --plugin-dir ~/dev/n1-plugin          # loads the working tree live; /reload-plugins to pick up edits
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
/n1:n1-review                      # review current branch (fix loop)
/n1:n1-review #340                 # advisory review of a PR
/n1:n1-pr                          # finalize branch: docs, push, create PR
/n1:n1-finish                      # verify PR is merged, watch deploy, close ticket
/n1:n1-queue --story STORY-12       # run story subtasks through the pipeline one by one (each ticket stops after PR + CI; N1 never merges, held tickets start once you merge their blocker). Also: --tag <tag>, --plan, --run <queue-id>, --dry-run, --status, --watch, --answer <ticket> <text>.
```

## Skills

| Skill | Description |
|-------|-------------|
| /n1:n1-benchmark | Benchmark orchestrator autonomy across versions (interventions per run, quality metrics, baseline deltas) |
| /n1:n1-clean | Remove git worktree for a ticket after work is done or abandoned |
| /n1:n1-finish | Verify the PR is merged (the human merges; prMode: skip merges locally), watch deploy, close ticket |
| /n1:n1-init | Set up N1 for your project (tracker, models, flags) |
| /n1:n1-pr | Finalize branch: docs, push, create PR |
| /n1:n1-review | Code review loop or advisory review of a PR |
| /n1:n1-start | Full pipeline orchestrator — ticket to merged PR |
| /n1:n1-queue | Run a batch of tracker tickets (by tag or story subtasks) through the pipeline one after another. Children never merge; held tickets start once you merge their blocker's PR. `--tag`, `--story`, `--plan` (persist a reviewable plan), `--run <queue-id>` (execute a saved plan), `--dry-run`, `--status`, `--watch` (the watch also shows an escalated child's full pending question), `--answer <ticket> <text>` (relays your reply back to the waiting child). |

### `/n1:n1-start` — Core Orchestrator

Single entry point for all task work. Full pipeline:

```
Input (ticket or brain dump)
  → Ticket read (product-analyst agent)
  → Codebase analysis (solution-architect agent)
  → Brainstorm (n1-brainstorm / brainstormer agent, with architect's analysis)
  → Plan (planner agent → n1-plan) — if complex
  → Implement (n1-implement + developer persona)
  → QA (qa-engineer agent)
  → Review (code-reviewer + security-reviewer agents, parallel)
  → Fix loop (developer agent, if needed)
  → PR (n1:n1-pr → tech-writer agent)
  → Tracker update
  → Stop after PR + CI: merge the PR, then run /n1:n1-finish
```

- **Agent personas:** 12 specialized agents with scoped tools and configurable models
- **Parallel security review:** code-reviewer and security-reviewer run simultaneously
- **Adaptive routing:** tasks that don't need a formal plan skip straight to implementation
- **Resume support:** interrupt anytime, `/n1:n1-start TRID-510` picks up where you left off
- **Confidence-based escalation:** low confidence + high blast radius = stop and ask

### `/n1:n1-review` — Code Review

Two modes:

| Mode | Trigger | Behavior |
|------|---------|----------|
| Review Loop | No args, on feature branch | code-reviewer + security-reviewer (parallel) → developer fixes → repeat until clean |
| Advisory | `/n1:n1-review #340` | code-reviewer report only, no fixes |

### `/n1:n1-pr` — Pull Request Creation

Spawns tech-writer agent for doc updates and PR content, pushes, creates PR via `gh`, and updates the tracker.

### `/n1:n1-finish` — Finish Work

Completes the cycle after PR/CI: verifies the PR is merged (it never merges a PR; it merges locally only for `git.prMode: skip`), always watches the deployment workflow on the merge commit when a push-triggered workflow exists, moves the tracker ticket to Done, and cleans up the branch/worktree. The ticket is closed only when the code is actually merged — never on green-CI-but-open.

- Standalone and idempotent
- Configure via `/n1:n1-init` or the `finishWork` block in `~/.n1/<project>/config.json`

```
/n1:n1-finish            # verify current branch's PR is merged, close ticket
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
6. Configures agent models (defaults or custom per-agent)
7. Creates `~/.n1/<project>/` state directory (v1 projects: offers migration from `.n1/`)
8. Adds `.claude/worktrees/` to `.gitignore`

### `/n1:n1-clean` — Worktree Cleanup

Removes the git worktree for a ticket after work is done or abandoned. Use when a worktree was not automatically cleaned up by `n1-finish` (e.g., when the finish step was skipped or the session was interrupted).

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

Tracker routing is config-driven via `~/.n1/<project>/config.json` (auto-derived from repo name at runtime) — all MCP tool names are mapped through operations presets populated by `n1-init`.

Created tickets can optionally be tagged with a service name. When `ticketTagging.enabled` is set (off by default; configured by `n1-init`), N1-created tickets get a `{service} | <title>` summary prefix and a `**Service:** <service>` line in the description.

Tickets N1 creates are auto-assigned to you (the authenticated tracker user) by default; `n1-start` also assigns unassigned tickets to you on pickup (e.g. via `n1-queue`). Set `tracker.assignToCreator` to `false` (or answer No during `n1-init`) to disable. Never steals an existing assignee from a ticket.

## Error Tracking Support

| Provider | MCP Server | Status |
|----------|------------|--------|
| Sentry | `sentry` (official MCP) | Supported |

Error tracking is optional and independent of tracker integration. When configured via `n1-init`, N1 accepts error-tracker issue URLs as input to `n1-start`. The product-analyst fetches structured error data (stack trace, breadcrumbs, event frequency, AI root-cause analysis) and the solution-architect searches for related issues during codebase analysis.

Sentry issues can optionally be promoted to tracker tickets (Jira/YouTrack) during the pipeline, or worked standalone with `sentry-<issueId>` as the working identifier.

## How It Works

N1 is a **lightweight controller** (~5-10K tokens) that uses a hybrid delegation model: 12 specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while native skills handle interactive steps (brainstorming, planning, implementation dispatch). Each agent gets fresh context with scoped tools, enforced at runtime by Claude Code's own agent allowlist.

### Agent Personas

| Agent | Default Model | Effort | Role |
|-------|---------------|--------|------|
| product-analyst | sonnet | low | Ticket distillation and requirements extraction |
| solution-architect | opus | medium | Codebase analysis and architecture assessment |
| planner | opus | medium | Isolated implementation-plan writing |
| implementer | sonnet | medium | n1-implement execution wrapper |
| developer | sonnet | medium | Implementation and review fix cycles |
| code-reviewer | opus | medium | Adversarial code quality review |
| security-reviewer | opus | medium | Security vulnerability review (OWASP, CWE) |
| qa-engineer | sonnet | medium | Test design and implementation |
| local-test-planner | sonnet | medium | Local test plan creation |
| post-deploy-verifier | sonnet | low | Acceptance-criterion verification after a successful deployment |
| tech-writer | sonnet | medium | PR content generation |

Defaults come from agent frontmatter; `models.*` in config is an explicit override that also disables signal-based tier adjustments for that agent.

### Per-Ticket Memory

Per-ticket memory lives in `~/.n1/<project>/memory/<ticket-id>/` (externalized, never inside the project tree) with semantic-named files and an explicit dependency map:

| Step | Reads | Writes |
|------|-------|--------|
| ticket | — | `ticket.md` |
| analysis | `ticket.md` | `analysis.md` |
| brainstorm | `ticket.md`, `analysis.md` | `brainstorm.md` |
| plan | `ticket.md`, `brainstorm.md`, `analysis.md` | `plan.md` |
| implementation | `brainstorm.md`, `plan.md` | `implementation.md` |
| qa | `ticket.md`, `implementation.md`, `plan.md` | `qa.md` |
| review | `ticket.md`, `brainstorm.md`, `implementation.md`, `qa.md` | `review.md` |
| pr | `overview.md`, `review.md`, `qa.md` | — |

The `~/.n1/<project>/` directory lives outside your project tree — tool state never gets committed to your repo. N1 uses git worktrees (`<project>/.claude/worktrees/<ID>/`) for isolation; only `.claude/worktrees/` needs to be gitignored (handled by `n1-init`).

Throwaway investigative tests and benchmarks (one-off probes that answer a question rather than verify shipped code) are written under `~/.n1/<project>/` too — they never land in your repo's test suite. Real unit/integration/e2e tests that cover the implemented feature are committed to the repo as usual.

## Escalation Model

**Fixed checkpoints (always):**
- After PR creation — Tech Lead reviews
- After PR creation — Codex Review runs automatically on every PR (opt-out: `crossHostReview.enabled: false` in config), posting findings as a PR comment. When the review ran, a read-only reviewer validates each Critical/High/Medium finding (every finding under hands-off autonomy, `qualityEscalations=auto-accept`, which never ends with an offer to fix), the developer fixes confirmed ones on the PR branch, and a triage comment lists fixed, dismissed and human-review findings (opt-out: `crossHostReview.autoTriage: false`). Session receipts record skipped reviews too; a Stop check requests continuation when the review step was missed. The benchmark reports review coverage per PR.

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
