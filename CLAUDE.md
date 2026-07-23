# CLAUDE.md

This file provides guidance to Claude Code when working with the n1-plugin repository.

## Repository Structure

```
github.com/maphnet/n1-plugin/
  skills/     N1 skills (auto-discovered by Claude Code)
  agents/     Agent persona definitions
  hooks/      Event hooks and scripts
  lib/        Shared shell library
  defaults/   Default config files
  .claude-plugin/plugin.json   Plugin manifest
```

See [README.md](README.md) for user-facing documentation: installation, quick start, skill usage examples, and full feature overview.

## Language Policy

ALL code, documentation, skills, agents, hooks, comments, and commit messages MUST be in English.
Russian is prohibited in any committed file.

## What This Is

N1 is a Claude Code plugin that orchestrates the full development cycle (ticket read, analysis, brainstorm, plan, implement, QA, review, [local testing], PR). It uses a **hybrid delegation model**: 9 specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while [Superpowers](https://github.com/obra/superpowers) ^5.0 sub-skills handle interactive steps (brainstorming, planning, implementation dispatch via SDD). It is a **thin controller** (~5-10K tokens per skill): skills load only the memory files they need, spawn agents or invoke Superpowers, and write results back to per-ticket memory.

**n1-start skill layout (v2.12.0):** `skills/n1-start/SKILL.md` is a thin dispatcher; each of the 16 pipeline step bodies lives in `skills/n1-start/steps/<step>.md` (one file per step name). Shared review logic (diff-surface classification, Codex probe + CODEX_ACTIVE gating, code-reviewer scope-narrowing) lives in `skills/n1-start/review-core.md`, referenced by both `steps/review.md` and `skills/n1-review/SKILL.md`.

## Stack

- **Runtime:** Bash (hooks), Markdown (skills, agents) — no npm, no Node.js
- **Plugin manifest:** `.claude-plugin/plugin.json`
- **Marketplace manifest:** `.claude-plugin/marketplace.json` (repo root — for `marketplace add`)
- **Dependency:** Superpowers plugin >=5.0
- **Shared shell helpers:** `lib/config.sh` (codex/model resolution), `lib/signals.sh` (signal read/write/gate evaluation), `lib/memory.sh` (compaction), `lib/cache.sh` (analysis snapshot I/O and freshness check)

## Plugin Development

**Always develop via `--plugin-dir`** — it loads the **working tree live** (uncommitted edits included). No install, no commit, no version bump, no reinstall.

```
claude --plugin-dir ~/dev/n1-plugin   # from a test project
# edit files → /reload-plugins → changes are live
```

Do NOT install N1 as a user-scope plugin for local development. A `file://` marketplace install copies from committed git HEAD into a cache, so local edits never show up without commit + version bump + reinstall.

### Notes for any future install/publish

- A `file://` marketplace install copies from committed git **HEAD** into a cache, not the working tree. Refreshing it requires a `version` bump (in `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, which must match) followed by `claude plugin marketplace update n1-plugin` + `claude plugin update n1-plugin@n1-plugin`.
- **Version bumps are mandatory for releases.** Any change that consumers should pick up requires a semver bump in **both** files. Without a bump, `plugin marketplace update` sees no change and consumers stay on the old version.
- Cross-marketplace dependencies (e.g. superpowers from `claude-plugins-official`) require `"marketplace"` in the dependency entry and `"allowCrossMarketplaceDependenciesOn"` in `marketplace.json`.
- `marketplace.json` lives at the repo root (`.claude-plugin/marketplace.json`) so `/plugin marketplace add maphnet/n1-plugin` can find it.
- The `git-subdir` source URL must be the full HTTPS URL (`https://github.com/maphnet/n1-plugin`), not the short `owner/repo` form — the short form resolves to SSH (`git@github.com:`) which fails without configured keys.

## Testing

- **Plugin:** `claude --plugin-dir ~/dev/n1-plugin` from any test project; `/reload-plugins` to pick up edits
- **Always test on a separate repo before committing plugin changes**
- **Dogfooding:** use N1 skills on the N1 repo itself

## Conventions

- **Skill authoring:** Always use `/writing-skills` skill when creating or modifying skills (available in Superpowers <=5.x; removed in v6)
- Skills: `skills/<name>/SKILL.md` — auto-discovered, invoked as `/n1:<skill-name>`
- Agents: `agents/<name>.md` — frontmatter requires `name`, `description`, `model`; optional `tools` (comma-separated allowlist of tool identifiers). Agents are dispatched as file-based subagents (by name), so Claude Code **enforces** this allowlist at runtime — it is a real capability boundary, not advisory. MCP tools must be named `mcp__<server>__<tool>`; a human label like "Tracker MCP" grants nothing. Omit `tools` entirely to inherit the orchestrator's full tool set — required when an agent needs config-dynamic tracker MCP tools whose names vary by tracker (e.g. product-analyst)
- Hooks: `hooks/hooks.json` — event declarations, scripts in `hooks/`
- One concern per file
- Skills invoke each other via `**REQUIRED SUB-SKILL:** Use plugin:skill-name` directives
- No Co-Authored-By trailers in commits
- **Timestamps:** Never let the model invent a timestamp — it has no clock and will hallucinate. Date-only needs (spec/plan filenames `YYYY-MM-DD`) use the harness-injected `currentDate`. Precise time (time-of-day, durations) must come from the `date` command, e.g. `date -u +%Y-%m-%dT%H:%M:%SZ`. Don't add timestamp fields unless something actually reads them — file mtime already records "last modified".
- **Test & benchmark artifacts:** Tests/benchmarks that verify committed implementation (unit, integration, e2e tied to acceptance criteria) go in the repo and run in CI. Throwaway probes that only answer a current question (approach micro-benchmarks, repro scripts, viability spikes) go under `$N1_HOME/` (external, never committed) — per-ticket `$N1_HOME/memory/<ID>/{benchmarks,tests}/`, or `$N1_HOME/scratch/{benchmarks,tests}/` when there is no ticket memory. When unsure, default to scratch. Bound into the `solution-architect`, `developer`, and `qa-engineer` personas; concrete paths are passed by the skills at spawn time.
- **Design specs:** `docs/superpowers/specs/` is gitignored. Design specs produced by brainstorming are working documents — leave them untracked, do not commit or force-add.
- **Agent spawns pass memory-file paths:** Skills pass the absolute path to each memory file (e.g. `$MEMORY_DIR/ticket.md`) so agents Read them directly. Exception: estimation inline data and the `## Key Decisions`/`## Escalations` slices of overview.md stay inlined. Read-only agents (code-reviewer, security-reviewer, codex-adapter, solution-architect) never write memory files; qa-engineer writes `qa.md` itself; developer fix cycles write/replace `## Fix Cycle <N>` sections in `implementation.md` — idempotent upsert, never duplicate.

## Architecture

### Orchestration Pattern

Skills are lightweight controllers that delegate all heavy work:

| N1 Skill | Delegates To | Purpose |
|----------|-------------|---------|
| n1-start | product-analyst, solution-architect, planner, implementer, qa-engineer agents + superpowers (brainstorming, writing-plans) | Full pipeline + single-step mode. Brainstorm step uses autonomous-brainstorm.md in step mode and investigation full-pipeline mode, superpowers:brainstorming in non-investigation full pipeline mode. Implementation uses implementer agent wrapping SDD (same pattern as planner wrapping writing-plans). |
| n1-review | code-reviewer, security-reviewer, developer agents | Review + fix loop |
| n1-pr | tech-writer agent + inline git/gh/MCP | Doc update, push, create or skip PR, update tracker, worktree cleanup |
| n1-ci | developer agent + inline gh CLI | Post-PR CI watch, classify failures, fix loop |
| n1-finish | (inline: gh + tracker MCP) | Merge verify/auto-merge, deploy watch, ticket close |
| n1-release | (inline: gh + git + tracker MCP) | Git tag, GitHub Release (or custom procedure), tracker comment |
| n1-init | (inline: analysis + prompts) | Project setup wizard (v2: migration flow) |
| n1-estimate | product-analyst, solution-architect agents + autonomous brainstormer + inline estimation | Standalone estimation |
| n1-clean | (inline: git worktree remove) | Worktree cleanup for abandoned or completed tickets |
| n1-story | intake-agent, product-analyst, solution-architect, tech-writer agents + inline interactive steps | Story decomposition: multi-repo analysis → discovery → design → publish → ticket creation |

Superpowers calls use the `superpowers:` prefix. Agent spawns use N1's own agent definitions. Each gets fresh context — the orchestrator never accumulates full history.

### Step Mode

`n1-start <ID> --step <name>` executes a single pipeline step and exits with a structured result:

```
N1_STEP_RESULT: {"step":"<name>","outcome":"<outcome>","next_step":"<name|null>","loop_counter":<object|null>}
```

Valid step names: `ticket`, `analysis`, `brainstorm`, `plan`, `plan-review`, `estimation`, `implementation`, `qa`, `review`, `fix`, `local-testing`, `pr`, `ci`, `finish`, `investigation-deliverable`, `release`.

n1-start owns the routing logic — the `next_step` field is authoritative. Config gates (`estimation.enabled`, `planReview.reviewPlan`, `localTesting.enabled`, `ciChecks.enabled`, `finishWork.enabled`, `release.enabled`) are respected; gated steps return `outcome: "skip"`. Fix step infers its target (QA or review) from overview.md state.

Without `--step`, behavior is unchanged (full pipeline, backward compatible).

### Investigation Mode

When a ticket matches a type's detection rules in the `pipeline.json` type registry (title match, tags, or type field — or an explicit `--type` flag), N1 runs that type's step sequence. The `investigation` type runs a shortened pipeline: ticket -> analysis -> brainstorm -> investigation-deliverable. The deliverable is a structured findings/recommendations document written to `investigation.md`. Implementation, QA, review, and PR steps are skipped.

Detection happens in the orchestrator after the ticket step via `n1_resolve_type()` (detection cascade: `--type` flag > tags > type field > title match > default). The resolved type is stored as `type: <name>` in overview.md frontmatter. Backward compat: if overview.md has `mode` but no `type`, `n1_read_type()` reads `mode` as `type`. Follow-up ticket creation and ticket closing are handled inline in the investigation-deliverable step (interactive mode only).

### Story Decomposition

When invoked via `/n1:n1-story`, N1 runs a 7-step pipeline for feature story decomposition: intake → analysis → discovery → design → review → publish → decompose.

- **Multi-repo analysis:** `--repos path1,path2` flag enables cross-repo architecture analysis. Solution-architect runs sequentially per repo with a final cross-repo synthesis pass.
- **Interactive discovery:** Extracts `uncertain`/`unknown` confidence-tagged items from analysis, presents them one-at-a-time for user resolution via Socratic Q&A.
- **Design output:** Phased design document with INVEST-validated tasks, Gherkin acceptance criteria, and XS–XL estimates.
- **Publishing:** Config-driven via `story.designStorage`: `"article"` (YouTrack KB / Confluence), `"ticket"` (description), or `"local"` (repo file). Falls back automatically.
- **Ticket creation:** One-by-one with user approval per subtask. Each created ticket is independently executable via `/n1:n1-start`.

Gated on `story.enabled` in config (default `false`). Configured by `n1-init`.

### Per-Ticket Memory (`$N1_HOME/`)

N1 state is **externalized** to `~/.n1/<project>/` (the `N1_HOME` directory), discovered via `git config n1.home`. This directory is set by `n1-init` and read by all skills and hooks. It never lives inside the project tree, so it requires no gitignore entry.

**N1_HOME resolution (skills):** run `git config n1.home`; expand `~`; if empty, fall back to `.n1` in the project root (backward compat for unmigrated projects).

**N1_HOME resolution (hooks — bash preamble):**
```bash
N1_HOME=$(git config n1.home 2>/dev/null || true)
if [ -n "$N1_HOME" ]; then
    N1_HOME="${N1_HOME/#\~/$HOME}"
else
    N1_HOME="${PWD}/.n1"  # backward compat
fi
```

Config file: `$N1_HOME/config.json` (renamed from `n1.config.json` in v2.0.0).

**Workspace isolation:** `n1-start` resolves isolation mode via: `--step` (always worktree) > `--worktree` flag > `worktree.mode` config (`"branch"` default, `"worktree"`) > branch. In branch mode, it creates a feature branch in the current checkout via `Ensure Working Branch`. In worktree mode, it creates a git worktree at `<main-checkout>/.claude/worktrees/<ID>/` via `Ensure Worktree`. `n1-pr` removes the worktree after push when `worktree.cleanup` is `"after-pr"`, regardless of how it was created.

**Worktree config options** (in `$N1_HOME/config.json`):
- `worktree.mode` — isolation mode for full-pipeline runs: `"branch"` (default, feature branch in current checkout) or `"worktree"` (worktree at `.claude/worktrees/<ID>/`). Overridable per-run with `--worktree` flag. Step mode always uses worktree regardless.
- `worktree.setup` — command to install dependencies in a worktree. Derived silently by `n1-init` from lockfiles (override for non-standard projects). Runs **lazily on first code-executing step** (implementation, or qa/review/local-testing on a resumed run), not at worktree creation — marker-guarded so it runs at most once per worktree.
- `worktree.cleanup` — when to auto-remove the worktree: `"after-pr"` (default, removed after push/PR) or `"manual"` (only via `/n1:n1-clean`)

Each step reads ONLY its declared dependencies:

| Step | Reads | Writes |
|------|-------|--------|
| ticket | — | `ticket.md` (+ `<!-- n1:signals -->` block: `task_type`, `has_acceptance_criteria`, `description_quality`) |
| analysis | `ticket.md` | `analysis.md` (+ signals: `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause`) |
| brainstorm | `ticket.md`, `analysis.md` | `brainstorm.md` (+ signals: `planning_need`, `design_clarity`, `approach_count`) |
| plan | `ticket.md`, `brainstorm.md`, `analysis.md` | `plan.md` |
| plan-review | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` | `plan.md` (in-place fixes) |
| estimation | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` (if exists) | `overview.md` (estimation section) |
| implementation | `brainstorm.md`, `plan.md` | `implementation.md` (+ signals: `diff_surface`, `lines_changed`, `new_files_count`) |
| qa | `ticket.md`, `implementation.md`, `plan.md` | `qa.md` (+ signals: `tests_added`, `tests_broken`, `coverage_change`) |
| review | `ticket.md`, `brainstorm.md`, `implementation.md`, `qa.md` | `review.md` |
| local-test-analysis | `ticket.md`, `implementation.md`, `plan.md` or `brainstorm.md`, codebase | `local-test-plan.md` |
| local-test-execution | `local-test-plan.md`, `implementation.md` | `local-testing.md` |
| local-test-fix | `local-testing.md`, `local-test-plan.md`, `implementation.md` | code fixes, then re-execution |
| pr | `overview.md` (full); verdict lines only from `review.md`, `qa.md`, `local-testing.md` (skip mode: `overview.md` only); `implementation.md` by path | `overview.md` (updates) |
| ci | `overview.md`, `plan.md`, `implementation.md` | `overview.md` (CI status) |
| finish | `overview.md`; PR state via gh | `overview.md` (Finish section) |
| release | `overview.md` (optional, for merge SHA); `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | tracker comment (best-effort) |
| investigation-deliverable | `ticket.md`, `analysis.md` | `investigation.md` |

Story pipeline memory (n1-story steps):

| Step | Reads | Writes |
|------|-------|--------|
| intake (story) | — | `ticket.md`, `story-overview.md` |
| analysis (story) | `ticket.md` | `analysis.md` |
| discovery | `ticket.md`, `analysis.md` | `discovery.md` |
| design | `ticket.md`, `analysis.md`, `discovery.md` | `story-design.md` |
| review (story) | `story-design.md`, `story-overview.md` | `story-design.md` (in-place fixes), `story-overview.md` |
| publish | `ticket.md`, `story-design.md`, `story-overview.md` | `story-overview.md` |
| decompose | `story-design.md`, `story-overview.md` | `story-overview.md` |

### Tracker Routing

Tracker MCP tool names are never hardcoded — they're resolved at runtime from `$N1_HOME/config.json` operations map. The `tracker.type` field (`"jira"` or `"youtrack"`) controls conditional branching (parameter shapes, cloudId resolution); the `tracker.mcp` field (e.g., `"jira-velosity"`, `"youtrack"`) controls MCP tool call prefix construction (`mcp__<tracker.mcp>__<operation>`). Two presets exist:

| Tracker | type | mcp value | Key operations |
|---------|------|-----------|---------------|
| Jira | `jira` | `plugin_atlassian_atlassian` | `getJiraIssue`, `transitionJiraIssue`, `addCommentToJiraIssue`, `getTransitionsForJiraIssue`, `atlassianUserInfo` (getCurrentUser), `editJiraIssue` (assign, editTicket) |
| YouTrack | `youtrack` | `youtrack` | `get_issue`, `update_issue` (moveStatus, editTicket), `add_issue_comment`, `get_issue_comments`, `get_current_user` (getCurrentUser), `change_issue_assignee` (assign) |

When `ticketTagging.enabled` is true, `n1-start` prefixes created tickets with `ticketTagging.service` (`{service} | title`) and adds a `**Service:**` line to the description. Off by default; configured by `n1-init`. Creation only — existing tickets are never re-tagged.

When `tracker.assignToCreator` is not `false` (default ON), `n1-start` assigns tickets it creates to the currently-authenticated tracker user via the `getCurrentUser` + `assign` operations. Creation only; non-fatal on failure; silently skipped when those operations are absent (legacy configs). Configured by `n1-init`.

On brain-dump/file runs where the user opts to create a ticket, `n1-start` adopts the **created ticket ID** as the per-ticket memory `<ID>` and worktree name. An ID-Final invariant blocks any memory/worktree write until that ID is known; if state was already written under the provisional slug, the idempotent `Reconcile Memory ID & Worktree` procedure moves the memory folder (inside `$N1_HOME/memory/`) and renames the worktree directory to the ticket-ID-based names.

### Type Registry

Workflow types are declared in `pipeline.json` under `types`. Each type defines its step sequence, detection rules, and optional per-step model overrides.

| Type | Steps | Detection | Key differences |
|------|-------|-----------|-----------------|
| `task` (default) | ticket → analysis → [brainstorm] → [plan] → [plan-review] → [estimation] → implementation → qa → review ⇄ fix → [local-testing] → pr → [ci] → [finish] → [release] | `detect.default: true` | Full pipeline |
| `investigation` | ticket → analysis → brainstorm → investigation-deliverable | Title match: `investigat`, tags: `investigation` | No implementation, QA, or PR |
| `bug` | ticket → analysis → [brainstorm] → [plan] → implementation → qa → review ⇄ fix → [local-testing] → pr → [ci] → [finish] → [release] | Type field: `bug`, tags: `bug` | Brainstorm/plan signal-gated: skipped when root cause known + blast radius not high + files < 5; analysis model downgraded |
| `chore` | ticket → analysis → implementation → qa → review → pr → [ci] → [finish] → [release] | Type field: `chore`, tags: `chore/config/deps` | Skips brainstorm, plan, local-testing; analysis and review models downgraded |

Brackets = skippable by config gates or runtime signals. Detection cascade: `--type` flag > tags > type_field > title_match > default.

Adding a new type requires only a `types` entry in `pipeline.json` — no new skills, step files, or orchestrator code changes.

### Runtime Signals

Steps emit runtime signals stored as `<!-- n1:signals -->` blocks in memory files. Signals drive step gating, model tiering, and decision telemetry.

| Step | Signals | Stored in |
|------|---------|-----------|
| ticket | `task_type`, `has_acceptance_criteria`, `description_quality` | ticket.md |
| analysis | `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause` | analysis.md |
| brainstorm | `planning_need`, `design_clarity`, `approach_count` | brainstorm.md |
| implementation | `diff_surface`, `lines_changed`, `new_files_count` | implementation.md |
| qa | `tests_added`, `tests_broken`, `coverage_change` | qa.md |

Helpers in `lib/signals.sh`: `n1_read_signal`, `n1_write_signals`, `n1_eval_signal_gate`, `n1_check_signal_gates`.

### Signal-Driven Gating

Signal gates in `pipeline.json` under `signal_gates` define `skip_when` conditions evaluated before each step. Safety invariants (qa, review, pr) are never skipped regardless of signals. Override hierarchy (highest wins): safety invariants > runtime signals > pipeline profile defaults > config gates.

### Model Tiering

`n1_resolve_model` accepts an optional context parameter for signal-driven model selection. Resolution chain: config override > signal-driven triggers > profile step_overrides > agent frontmatter default. Tier keywords: `frontier` (opus), `standard` (agent default), `downgrade` (one tier below), `minimal` (haiku). Triggers defined in `pipeline.json` under `downgrade_triggers` and `escalation_triggers`.

### Memory Compaction

`n1_compact_memory` in `lib/memory.sh` archives full memory files to `<file>.full.md` and replaces originals with compacted versions keeping only high-signal sections. Applied after brainstorm (291K → <10K target), analysis (30-50% reduction), and implementation before review (40-60% reduction).

### Analysis Cache

Optional project-level snapshot that eliminates redundant codebase discovery on sequential tickets. Gated on `analysisCache.enabled` in `$N1_HOME/config.json` (default `false`).

**Snapshot location:** `$N1_HOME/cache/project-snapshot.md` — structured, schema-versioned document with provenance comments per section. Not a memory file — it's a cache artifact scoped to the project, not a ticket.

**Lifecycle:** First ticket (cold start) generates the snapshot as a byproduct of full analysis. Subsequent tickets (warm start) inject it into the solution-architect's prompt, skipping project-level discovery. Stale snapshots trigger full regeneration.

**Invalidation (full-snapshot, v1):** git-diff-based classification against `analysisCache.structuralFiles` (force stale), neutral-file threshold (`analysisCache.neutralThreshold`, default 15), and TTL (`analysisCache.ttl`, default `"4h"`). Provenance comments stored per section for future partial invalidation.

**Fail-open:** Any cache failure (corrupt file, missing SHA, git error) falls back to full analysis. `SNAPSHOT_DRIFT` markers from the agent force regeneration on the next ticket.

**Helpers:** `lib/cache.sh` — `n1_snapshot_path`, `n1_snapshot_check_freshness`, `n1_snapshot_read_body`, `n1_snapshot_write`, `n1_parse_ttl`.

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `analysisCache.enabled` | boolean | `false` | Master gate |
| `analysisCache.ttl` | string | `"4h"` | Max age before forced regeneration |
| `analysisCache.neutralThreshold` | integer | `15` | NEUTRAL files changed before invalidation |
| `analysisCache.structuralFiles` | string[] | See `defaults/analysis-cache.json` | Glob patterns for structural files |

### Implementation Simplicity Gate

When `tier == simple` AND `blast_radius == low` AND `files_changed < 3`, the implementation step bypasses SDD fan-out and spawns a single developer agent directly. Fallback to full SDD if the developer fails. Gate checked before the existing planning_need routing.

### Ticket Description Enrichment

Optional two-phase enrichment that writes structured content back to the tracker when a ticket description is poor or absent. Gated on `ticketEnrichment.enabled` (default true) and the `editTicket` operation existing in config.

- **Phase 1** (product-analyst, Step 1): quality assessment (Empty / Skeletal / Weak / Adequate) → silent append for empty/skeletal descriptions, silent rewrite for weak descriptions. Idempotency markers: `*Structured by N1*` / `*Restructured by N1*`.
- **Phase 2** (orchestrator, after Step 3 Brainstorm): appends refined acceptance criteria and scope boundaries to description, posts a design summary comment. Idempotency marker: `*Refined after design review — N1*`.

Both phases are non-blocking — MCP failures are logged and skipped. Freshly created tickets (brain-dump/file/error-tracker modes) skip Phase 1 (adequate by construction).

### Estimation

Optional complexity classification and delivery time estimation. Gated on `estimation.enabled` (default false) in `$N1_HOME/config.json`. When enabled, the orchestrator classifies task complexity into tiers (XS/S/M/L/XL), maps to a configurable time estimate, and writes results to overview.md + tracker ticket (description append + time field).

- **Pipeline integration:** after plan when `planning_need: plan` (Step 4c), after planning need routing when `planning_need: direct`. Uses the best available context — plan.md when present, brainstorm.md otherwise.
- **Standalone:** `n1-estimate` skill runs Steps 1–3 (ticket → analysis → brainstorm) then estimates. No implementation, no branch creation, no status transitions.
- **Default mapping** in `defaults/estimation.json`: XS=30m, S=2h, M=6h, L=2d, XL=5d. Overridable per-project via `estimation.mapping` in config (partial overrides merge with defaults).
- **Tracker writes:** Jira `originalEstimate` via `editJiraIssue`, YouTrack `Estimation` field via `update_issue`. Both non-blocking. Idempotency marker: `*Estimated by N1*`.

### Local Testing

When `localTesting.enabled` is true, n1-start runs a local end-to-end testing phase (Step 9) after Review and before PR. Local-test-planner produces a test plan, prints a summary, and developer executes automatically. Bounded fix loop: `localTesting.maxFixAttempts` (default 3). Off by default; configured by `n1-init`.

The PR body uses a unified `## Verification` section (not separate `## Test Plan` / `## Local Testing`). The tech-writer merges QA verification steps with local testing results via best-effort semantic matching — matched items show checked/unchecked with evidence, unmatched items from either source are included as-is.

### Test Coverage Tiers

Configurable QA behavior controlled by `testCoverage.tier` in `$N1_HOME/config.json` (default `"maintain"` when absent). Three tiers:

| Tier | QA behavior |
|------|-------------|
| **maintain** (default) | Run existing tests, fix breakage, update for changed functionality. No new tests. |
| **minimal** | Maintain + 1–3 focused behavioral tests per feature, acceptance-criteria-only |
| **standard** | Minimal + edge cases + error paths, capped at 10 per test file / 3 per group |

Cross-tier invariants: broken tests are always fixed, tests for removed functionality are always updated, pre-existing assertions are never silently rewritten.

The code-reviewer evaluates a **Test Quality (TQ)** dimension with `[TQ-N]` prefix findings. TQ-High (assertion rewriting) causes review FAIL; Medium/Low are non-blocking. A TQ fix loop (Step 7b in n1-start) spawns the QA agent to fix flagged tests before the review fix loop.

### Error Tracking Routing

Optional integration with error-tracking systems (Sentry first, extensible to Datadog/Rollbar). Config-driven via `errorTracking` block in `$N1_HOME/config.json` — same operations-map pattern as tracker routing. When `errorTracking` is `null` or absent, the feature is fully disabled.

| Provider | mcp value | Key operations |
|----------|-----------|---------------|
| Sentry | `sentry` | `get_sentry_issue` (getIssue), `search_sentry_issues` (searchIssues), `list_projects` (listProjects), `get_autofix_state` (getAiAnalysis) |

Two pipeline touchpoints:
- **Intake** (n1-start + product-analyst): URL detection via `errorTracking.urlPattern`, MCP fetch of issue data + optional AI root-cause analysis, structured `ticket.md` with error-specific sections
- **Analysis** (solution-architect): search for related issues via `errorTracking.operations.searchIssues`, reported in `analysis.md`

Memory ID for error-tracker runs: `sentry-<issueId>` (provisional; replaced by tracker ticket ID if user creates one). Ticket creation is optional — reuses the brain-dump ticket-creation flow with a Sentry link prepended to the description.

@references/codex-review.md

### Finish Work

Optional final pipeline step (`finish`) that runs after CI, gated on `finishWork.enabled` (default `false`) in `$N1_HOME/config.json`. The standalone `/n1:n1-finish` skill works regardless of the gate — it's a merge-verify + close command any time. The ticket is closed **only when the code is actually merged**, never on green-CI-but-open.

- **Merge:** `mergeOnFinish` (default `false`, reviewer merges) triggers `gh pr merge --auto --<mergeMethod> --delete-branch` when enabled. Projects with `git.prMode: "skip"` have no PR — finish performs a local merge into the default branch and explicitly does **not** push.
- **Deploy watch** (`deployWatch.enabled`, default `false`): polls `gh run list --commit <sha>` for workflow runs on the merge commit, optionally filtered by `workflowName`. Deploy failure leaves the ticket open.
- **Ticket close:** requires `tracker.statuses.done` in config (detected by `n1-init`, or added manually); absent → finish skips closing with an explanatory message.

### Release

Optional final pipeline step (`release`) that runs after finish, gated on `release.enabled` (default `false`) in `$N1_HOME/config.json`. The standalone `/n1:n1-release` skill works regardless of the gate.

Two modes: built-in gh flow (`procedure: null`) creates an annotated git tag and GitHub Release via `gh release create --generate-notes`; custom flow (`procedure: "<markdown>"`) walks the user through a pasted markdown procedure with placeholder substitution (`{{RELEASE_TAG}}`, `{{VERSION}}`, `{{MERGE_SHA}}`, `{{TICKET_ID}}`).

Idempotent: `gh release view` check before creating; existing tag/release causes a skip. Tracker comment ("Released as vX.Y.Z") posted best-effort when a ticket can be inferred from the branch name.

Config keys: `release.enabled` (boolean, default `false`), `release.tagPrefix` (string, default `"v"`), `release.procedure` (string|null, default `null`), `release.draft` (boolean, default `false`).

### Agent Personas

11 atomic agents with scoped tools and configurable models:

| Agent | Default Model | Tools | Pipeline Stage |
|-------|---------------|-------|----------------|
| product-analyst | sonnet | inherits (needs dynamic tracker + error-tracking MCP) | Ticket read, Error intake, Description enrichment |
| solution-architect | opus | Read, Grep, Glob, Bash, WebSearch, WebFetch | Analysis, Bug investigation, Plan review (CCR) |
| planner | opus | Read, Grep, Glob, Write, Edit, Skill, WebSearch, WebFetch | Plan writing |
| implementer | opus | inherits (needs Skill for SDD, Agent for SDD subagents) | Implementation (wraps SDD) |
| developer | opus | Read, Edit, Write, Bash, Grep, Glob | Fix cycle, CI fix |
| code-reviewer | opus | Read, Grep, Glob | Review (parallel) |
| security-reviewer | opus | Read, Grep, Glob | Review (parallel) |
| codex-adapter | sonnet | (none) | Review (Codex output parsing, conditional) |
| qa-engineer | sonnet | Read, Edit, Write, Bash, Grep, Glob | QA (tier-aware: maintain/minimal/standard) |
| local-test-planner | sonnet | Read, Grep, Glob, Bash | Local testing (plan creation) |
| tech-writer | sonnet | Read, Grep, Edit, Write, Glob | Doc update, PR content |

Models default to agent frontmatter values, overridable via `models` section in `$N1_HOME/config.json`.

**Trusted web research (always on).** `solution-architect` and `planner` carry `WebSearch, WebFetch` to research industry standards, best practices, and practitioner experience during analysis, planning, and plan-review. Research is constrained by the shared rubric in `agents/research-standards.md`: trusted source tiers, a marketing reject-list, ≥2-source corroboration, mandatory URL citation, a standards-over-soft-practices fitness gate (guards against over-engineering), and graceful degradation when the network is unavailable. Library API docs still go through Context7, not web search.
- **Single-pass analysis & research (v2.11.0):** the pre-plan `solution-architect` "deeper analysis" re-spawn was removed — the Step-2 `analysis.md` plus the `planner`'s native file discovery feed planning, and plan-review (4b) is the assumption safety net. Web research runs once (Step 2); 4b validates against the standards already recorded in `analysis.md` rather than re-researching.

### Session Start Hook

`hooks/session-start.sh` fires on session start/resume/clear/compact. It resolves `N1_HOME` via `git config n1.home` (falling back to `.n1/` in the project root for unmigrated projects), then reads `$N1_HOME/config.json` and injects context telling Claude to prefer N1 skills. When a tracker is configured, it also injects a **TRACKER ROUTING** directive containing the tracker type, MCP server name, full operations map, and a negative instruction to never use any other MCP server. This keeps the correct MCP server name in the model's attention window throughout the session. After running `n1-init`, the user must `/clear` or restart to pick up the new config.

@references/telemetry.md

### Escalation Protocol

The loop controller uses a file-based escalation callback protocol for steps that need user input. All escalating steps (brainstorm, qa, review, local-testing) write a uniform `escalation/request.json` under `$N1_HOME/memory/<ID>/escalation/`; the loop controller reads it, delivers the question via a pluggable I/O adapter, collects the response, writes it to `escalation/response.json`, and re-runs the step. Only two files exist at any time; each round overwrites the previous. Directory is deleted on step completion.

Two autonomy profiles control escalation behavior:

| Profile | Margin | Timeout | On timeout |
|---------|--------|---------|------------|
| `balanced` (default) | 0.15 | 30 min | pause |
| `autonomous` | 0.05 | 10 min | proceed with recommendation |

Configured via `loop.autonomy` in `$N1_HOME/config.json`. Individual settings overridable via `loop.escalation.*`.

### Escalation Model

Fixed checkpoints: after PR creation (Tech Lead reviews). Plan checkpoint is off by default (`requirePlanApproval: false`) — the plan-review CCR step validates the plan automatically. Enable `requirePlanApproval: true` to restore the manual plan checkpoint.
Confidence-based: low confidence + high blast radius = stop and ask.
Always escalate: security, architecture, public API changes.

## Git

- Default branch: `main`
- Commit style: imperative mood, English
- No Co-Authored-By trailers
- **Version bump is mandatory on every task branch.** Before the PR/merge step, bump the patch version in BOTH `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` (they must match). Commit as `chore: bump version to <new> (<ID>)`. Without a bump, `plugin marketplace update` sees no change and consumers stay on the old version.
- **Workspace isolation lifecycle:** `n1-start` resolves isolation mode via: `--step` > `--worktree` flag > `worktree.mode` config > default branch. In branch mode, it creates a feature branch eagerly in Step 1 via `Ensure Working Branch`. In worktree mode, it creates a worktree at `<main-checkout>/.claude/worktrees/<ID>/` via `Ensure Worktree`. `n1-pr` performs `git push -u origin <branch>` and removes the worktree after push when `worktree.cleanup` is `"after-pr"` (skipped entirely when `git.prMode` is `"skip"`); in branch mode the branch is preserved.
