# N1 (No-One)

AI-driven development orchestrator for Claude Code. No one writes the code.

N1 is a Claude Code plugin that orchestrates the full development cycle using 12 specialized agent personas and [Superpowers](https://github.com/obra/superpowers) sub-skills. Agents handle autonomous work (analysis, QA, review, fixes, PR content); Superpowers handles interactive steps (brainstorming, planning, implementation dispatch). Adds tracker integration, per-ticket memory, adaptive workflow routing, confidence-based escalation, parallel security review, and a mandatory review loop.

The full N1 workflow below is for Claude Code. A separate, opt-in Codex/Pi package exists only for an **unsupported, read-only runtime-review preview**; it does not provide `n1-start`, the full pipeline, or a qualified live review.

## Requirements

### Claude Code full workflow

- [Claude Code](https://code.claude.com/docs/en/overview) 2.1+
- [Superpowers](https://github.com/obra/superpowers) plugin >=6, from the `claude-plugins-official` marketplace
- `git` and `gh` (GitHub CLI) on PATH
- Optional: Jira (Atlassian MCP) or YouTrack MCP for tracker integration
- Optional: Sentry MCP for error-tracking integration

### Codex/Pi runtime-review preview only

Use a disposable host home and an assembled package outside the checkout. The Pi lane requires Node `>=24.19.0 <25` and Pi `0.85.1`; its dependencies are installed explicitly with `npm ci`. Installation proves package loading only: the current capability gates stop before source preparation, worker dispatch, or a live model review.

## Installation

### Claude Code — full workflow

Follow the [Claude Code plugin guide](https://code.claude.com/docs/en/plugins). N1 declares Superpowers from its actual marketplace identity, `claude-plugins-official`. Install that dependency first: in an isolated Claude `2.1.258` probe, this order enabled Superpowers `6.3.0` and source N1 `3.0.0` with no dependency errors.

```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin install superpowers@claude-plugins-official --scope user --yes
claude plugin marketplace add maphnet/n1-plugin
claude plugin install n1@n1 --scope user --yes
```

Installing N1 before Superpowers produced a dependency-resolution error in the same isolated test. The ordering is therefore deliberate. The equivalent interactive commands are `/plugin marketplace add maphnet/n1-plugin` and `/plugin install n1@n1`.

Then enable auto-update: `/plugin` → Marketplaces → n1 → Auto-update.

For local development:

```bash
claude --plugin-dir ~/dev/n1-plugin
```

As observed on 2026-09-12, the published N1 marketplace served `2.103.0`, while this source package is `3.0.0` and contains the preview adapters; use a checked-out branch/ref for unreleased adapter work. An isolated live Claude attempt also requires a logged-in host, and no full live runtime-review E2E is claimed here.

### Codex — local runtime-review preview (unsupported)

Codex has no advertised N1 remote marketplace in this repository; see the [Codex plugin documentation](https://developers.openai.com/codex/plugins/) for its native lifecycle. Clone the exact branch/ref you need, assemble it to an absolute path outside the checkout, and keep every directory in the assembled package together:

```bash
git clone --branch agent-agnostic https://github.com/maphnet/n1-plugin.git /absolute/n1-source
cd /absolute/n1-source
python3 scripts/package-review-preview.py \
  --host codex \
  --destination /absolute/n1-home/scratch/reviews/packages/20260912-preview/codex
```

Codex's native local-package path is a disposable marketplace wrapper. Create the wrapper JSON and symlink exactly as shown in the [runtime-preview reference](references/runtime-review-preview.md#enable-and-check-codex), then use a dedicated home:

```bash
mkdir -p /absolute/disposable-codex-home
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin marketplace add /absolute/n1-runtime-marketplace
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin add runtime-review@n1-review-runtime
CODEX_HOME=/absolute/disposable-codex-home codex plugin list --json
```

Restart Codex with that same dedicated home before attempting its discovered skill:

```bash
CODEX_HOME=/absolute/disposable-codex-home codex
# In the new Codex session: $runtime-review:n1-review-runtime owner/repo#123
```

Remove the same opt-in setup with:

```bash
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin remove runtime-review@n1-review-runtime
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin marketplace remove n1-review-runtime
```

With `codex-cli 0.154.0`, repeated native installation left one enabled registration, and native discovery reported `runtime-review:n1-review-runtime` (plugin ID `runtime-review@n1-review-runtime`). That is distinct from the skill basename `n1-review-runtime`; it does not promise an invocation. The packaged preflight rejects an explicit target as unsupported, and a Codex live attempt in an unauthenticated disposable home stopped at HTTP 401 before the skill ran.

### Pi — local runtime-review preview (unsupported)

See Pi's [extension documentation](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md). Reuse the checked-out branch/ref above (or clone it first), build the Pi package, keep the entire assembled package together, then install its pinned dependency and extension in a dedicated Pi home:

```bash
cd /absolute/n1-source
python3 scripts/package-review-preview.py \
  --host pi \
  --destination /absolute/n1-home/scratch/reviews/packages/20260912-preview/pi

PKG=/absolute/n1-home/scratch/reviews/packages/20260912-preview/pi
PI_HOME=/absolute/disposable-pi-home
PI_CLI="$PKG/adapters/pi/preview/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js"
EXT="$PKG/adapters/pi/preview/extensions/review.ts"
npm --prefix "$PKG/adapters/pi/preview" ci --ignore-scripts --no-audit --no-fund
PI_CODING_AGENT_DIR="$PI_HOME" node "$PI_CLI" install "$EXT"
PI_CODING_AGENT_DIR="$PI_HOME" node "$PI_CLI" list
```

For development or isolated qualification, load the relocated extension explicitly (rather than relying on discovery):

```bash
PI_CODING_AGENT_DIR="$PI_HOME" PI_OFFLINE=1 PI_TELEMETRY=0 \
  node "$PI_CLI" --offline --no-session --no-extensions --no-skills \
  --no-prompt-templates --no-themes --no-context-files \
  --extension "$EXT" \
  --print '/n1-review-runtime owner/repo#123'
```

Use Pi's native removal command against the same dedicated home, then confirm `list` is empty:

```bash
PI_CODING_AGENT_DIR="$PI_HOME" PI_OFFLINE=1 PI_TELEMETRY=0 \
  node "$PI_CLI" remove "$EXT"
PI_CODING_AGENT_DIR="$PI_HOME" node "$PI_CLI" list
```

Node `24.19.0`/Pi `0.85.1` successfully built, installed, listed, removed, and passed the 21 package tests. In an isolated empty model registry, a missing target was rejected and an explicit target stopped at the inherited-model gate; Pi reports extension errors in its output even when the launcher exits 0. A follow-up against an existing native registry reached the package gate, which rejected unverified `isolatedContext` evidence before source preparation or workers. The Codex discovery name above is likewise unverified for execution. This is fail-closed evidence, not a completed model review.

## Quick Start (Claude Code only)

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
/n1:n1-pr                          # finalize branch: docs, push, create PR
/n1:n1-finish                      # verify/merge PR, watch deploy, close ticket
/n1:n1-story-run STORY-12          # implement a whole story: subtasks run one by one through n1-start in their own repos, then a summary is posted on the story. --dry-run shows the plan only.
```

## Skills (Claude Code only)

| Skill | Description |
|-------|-------------|
| /n1:n1-benchmark | Benchmark orchestrator autonomy across versions (interventions per run, quality metrics, baseline deltas) |
| /n1:n1-clean | Remove git worktree for a ticket after work is done or abandoned |
| /n1:n1-estimate | Estimate task complexity and delivery time |
| /n1:n1-finish | Verify/merge PR, watch deploy, close ticket |
| /n1:n1-init | Set up N1 for your project (tracker, models, flags) |
| /n1:n1-pr | Finalize branch: docs, push, create PR |
| /n1:n1-review | Code review loop or advisory review of a PR |
| /n1:n1-start | Full pipeline orchestrator — ticket to merged PR |
| /n1:n1-story-run | Implement a whole story: subtasks run one by one through n1-start in their own repos, then a summary is posted on the story. `--dry-run` shows the plan only. |

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

Completes the cycle after PR/CI: verifies the PR is merged (or merges it when `finishWork.mergeOnFinish` is enabled), optionally watches the deployment workflow triggered by the merge commit, moves the tracker ticket to Done, and cleans up the branch/worktree. The ticket is closed only when the code is actually merged — never on green-CI-but-open.

- Standalone and idempotent — works with or without the `finishWork.enabled` pipeline gate
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
8. Creates `~/.n1/<project>/` state directory (v1 projects: offers migration from `.n1/`)
9. Adds `.claude/worktrees/` to `.gitignore`

### `/n1:n1-estimate` — Task Estimation

Estimates task complexity and delivery time. Runs the analysis pipeline (ticket read → codebase analysis → brainstorm), classifies complexity into a tier (XS–XL), and maps to a time estimate.

- Writes estimate to tracker ticket (description + time field) when enabled
- Reuses existing analysis if the ticket was previously analyzed
- No branch creation or status transitions — read-only analysis
- Configure via `/n1:n1-init` or set `estimation.enabled: true` in `~/.n1/<project>/config.json`

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

When enabled, estimation runs automatically in the `n1-start` pipeline (after plan when `planning_need: plan`, after brainstorm when `planning_need: direct`) and writes to the tracker's time field (Jira `originalEstimate`, YouTrack `Estimation`). Use `/n1:n1-estimate` standalone to estimate without running the full pipeline.

## How It Works

N1 is a **lightweight controller** (~5-10K tokens) that uses a hybrid delegation model: 12 specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while Superpowers sub-skills handle interactive steps (brainstorming, planning, implementation dispatch via SDD). Each agent gets fresh context with scoped tools.

### Agent Personas

| Agent | Default Model | Effort | Role |
|-------|---------------|--------|------|
| product-analyst | sonnet | low | Ticket distillation and requirements extraction |
| solution-architect | opus | medium | Codebase analysis and architecture assessment |
| planner | opus | medium | Isolated implementation-plan writing |
| implementer | sonnet | medium | SDD execution wrapper |
| developer | sonnet | medium | Implementation and review fix cycles |
| code-reviewer | opus | medium | Adversarial code quality review |
| security-reviewer | opus | medium | Security vulnerability review (OWASP, CWE) |
| qa-engineer | sonnet | medium | Test design and implementation |
| intake-agent | haiku | low | Ticket/content intake |
| local-test-planner | sonnet | medium | Local test plan creation |
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
