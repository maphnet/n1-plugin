# N1 Architecture Reference

## Orchestration Pattern

Skills are lightweight controllers that delegate all heavy work:

| N1 Skill | Delegates To | Purpose |
|----------|-------------|---------|
| n1-start | product-analyst, solution-architect, planner, implementer, qa-engineer agents + superpowers (brainstorming, writing-plans) | Full pipeline. Brainstorm step uses autonomous-brainstorm.md when `BRAINSTORM_MODE` is `auto`; superpowers:brainstorming in interactive mode (investigation included — `--investigate` forces interactive). Implementation uses implementer agent wrapping SDD (same pattern as planner wrapping writing-plans). |
| n1-review | code-reviewer, security-reviewer, developer agents | Review + fix loop |
| n1-pr | tech-writer agent + inline git/gh/MCP | Doc update, push, create PR, update tracker |
| n1-ci | developer agent + inline gh CLI | Post-PR CI watch, classify failures, fix loop |
| n1-finish | (inline: gh + tracker MCP) | Merge verify/auto-merge, deploy watch, ticket close, worktree cleanup |
| n1-release | (inline: gh + git + tracker MCP) | Git tag, GitHub Release (or custom procedure), tracker comment |
| n1-init | (inline: analysis + prompts) | Project setup wizard (v2: migration flow) |
| n1-estimate | product-analyst, solution-architect agents + autonomous brainstormer + inline estimation | Standalone estimation |
| n1-clean | (inline: git worktree remove) | Worktree cleanup for abandoned or completed tickets |
| n1-ticket | solution-architect agent + inline context capture, web research, tracker MCP | Create a single backlog ticket (Task/Bug) from conversation context |
| n1-story | solution-architect agent + inline context capture, interactive discovery, tracker MCP | Create a story with subtask tickets from conversation context |
| n1-story-run | headless `claude -p` child per subtask (n1-start, n1-finish), solution-architect (order gap-fill), tracker MCP | Implement a whole story: validate → sequential subtask pipelines in each subtask's repo → summary comment |
| n1-rules | (inline: lib/rules.sh) | List, add, validate project rules; regenerate deny hook |

Superpowers calls use the `superpowers:` prefix. Agent spawns use N1's own agent definitions. Each gets fresh context — the orchestrator never accumulates full history.

## Investigation Mode

When a ticket matches a type's detection rules in the `pipeline.json` type registry (tags or type field, or an explicit `--type` flag; titles never route — a title that reads like an investigation only prints a hint), N1 runs that type's step sequence. The `investigation` type runs a shortened pipeline: ticket -> analysis -> brainstorm -> investigation-deliverable. The deliverable is a structured findings/recommendations/metrics document written to `investigation.md` with signals (`confidence`, `implementable`, `unknowns_resolved`, `findings_count`, `recommendations_count`). Implementation, QA, review, and PR steps are skipped. During analysis and deliverable production, the agent classifies unknowns into A/B/C tiers (matching the brainstormer pattern): A-tier (human-only) are flagged via `<!-- n1:unknown -->` markers and presented to the user; B-tier (code-answerable) are self-resolved via codebase exploration and marked with `<!-- n1:resolved -->`. Only A-tier unknowns reach the user Q&A phase. After the deliverable, tracker enrichment writes findings back to the ticket (description append + comment), and post-investigation routing offers three options: create a new linked implementation ticket, convert the current ticket to implementation, or close. The `--investigate` flag forces the investigation type explicitly and makes the brainstorm step interactive (`superpowers:brainstorming` with a research-focus override) regardless of `autonomy.brainstorm`; the marker is persisted as `investigate_interactive: true` in overview.md frontmatter. In brain-dump mode the flag defers tracker ticket creation until after the deliverable: the user is asked at the end whether to create a ticket (memory is then reconciled from the provisional slug to the real ID). Converting to implementation rewrites overview.md frontmatter (`type: task`, `step: brainstorm`) and the progress checklist, then offers to continue in-session straight into planning-need routing — or resume later via `/n1:n1-start <ID>`.

Detection happens in the orchestrator after the ticket step via `n1_resolve_type()` (detection cascade: `--type` flag > tags > type_field > default). The resolved type is stored as `type: <name>` in overview.md frontmatter; the winning rule is stored as `type_matched_by` in overview.md frontmatter. A project where most tickets resolve by `default` has a tracker-hygiene problem, not a routing one. Backward compat: if overview.md has `mode` but no `type`, `n1_read_type()` reads `mode` as `type`. Post-investigation routing (create linked ticket, convert to implementation, or close) is handled in the investigation-deliverable step. Tracker enrichment (description append + comment) runs unconditionally.

## Ticket & Story Creation

`/n1:n1-ticket` and `/n1:n1-story` create backlog tickets from conversation context and/or a brain dump argument. Both are single-file skills with no persistent memory — the tracker is the source of truth.

- **n1-ticket:** Captures context → light analysis (solution-architect, low effort) → optional web research → bug type detection → approval gate → creates one Task or Bug ticket.
- **n1-story:** Captures context → deeper analysis (solution-architect, standard effort) → interactive discovery of unknowns → designs subtask decomposition → approval gate → creates a Story ticket with linked subtasks.

Neither command transitions ticket status or creates branches. Both mention `/n1:n1-start <ID>` as the next step.

## Per-Ticket Memory (`$N1_HOME/`)

N1 state is **externalized** to `~/.n1/<project>/` (the `N1_HOME` directory). This directory is set by `n1-init` and read by all skills and hooks via `n1_home()` in `lib/config.sh`. It never lives inside the project tree, so it requires no gitignore entry.

**N1_HOME resolution** (single source of truth: `lib/config.sh:n1_home()`):

1. `$N1_HOME` env var — if set, used as-is (platform-local override for cross-platform repos)
2. Auto-derive: `$HOME/.n1/<slug>/` — tries remote-URL slug first (`basename $(git remote get-url origin) .git`), then directory-name slug (`basename $(git rev-parse --show-toplevel)`), both lowercased and sanitized; returns whichever matches an existing directory
3. `git config n1.home` — legacy backward compat; tilde expansion; WSL `wslpath` conversion
4. In-repo `.n1/` fallback (legacy unmigrated projects)

**All skills and hooks** resolve via:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

Config file: `$N1_HOME/config.json` (renamed from `n1.config.json` in v2.0.0).

**Workspace isolation:** `n1-start` resolves isolation mode via: external worktree detection (highest priority) > `--branch` flag > `worktree.mode` config (`"worktree"` default, `"branch"`, `"external"`) > worktree. When an external worktree is detected (linked git worktree not under `.claude/worktrees/`), or `worktree.mode` is `"external"`, N1 skips worktree and branch creation and operates on the current checkout and branch. In worktree mode, it creates a git worktree at `<main-checkout>/.claude/worktrees/<ID>/` via `Ensure Worktree`. In branch mode, it creates a feature branch in the current checkout via `Ensure Working Branch`. `n1-finish` removes the worktree after merge when `worktree.cleanup` is `"after-pr"` or `"after-merge"`, regardless of how it was created.

**Worktree config options** (in `$N1_HOME/config.json`):
- `worktree.mode` — isolation mode: `"worktree"` (default, worktree at `.claude/worktrees/<ID>/`), `"branch"` (feature branch in current checkout), or `"external"` (force external worktree mode — skip all isolation, reuse current checkout and branch). Auto-detection of external worktrees takes precedence over all modes except `"external"` itself. Overridable per-run with `--branch` flag.
- `worktree.setup` — command to install dependencies in a worktree. Derived silently by `n1-init` from lockfiles (override for non-standard projects). Runs **lazily on first code-executing step** (implementation, or qa/review/local-testing on a resumed run), not at worktree creation — marker-guarded so it runs at most once per worktree.
- `worktree.cleanup` — when to auto-remove the worktree: `"after-merge"` (default, removed after merge by n1-finish; `"after-pr"` is a permanent backward-compatible alias) or `"manual"` (only via `/n1:n1-clean`). Does not apply to external worktrees (cleanup is skipped automatically via path gate).

Each step reads ONLY its declared dependencies:

| Step | Reads | Writes |
|------|-------|--------|
| ticket | — | `ticket.md` (+ `<!-- n1:signals -->` block: `task_type`, `has_acceptance_criteria`, `description_quality`) |
| analysis | `ticket.md` | `analysis.md` (+ signals: `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause`) |
| brainstorm | `ticket.md`, `analysis.md` | `brainstorm.md` (+ signals: `planning_need`, `design_clarity`, `approach_count`) |
| plan | `ticket.md`, `brainstorm.md`, `analysis.md` | `plan.md` |
| plan-review | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` | `plan.md` (in-place fixes) |
| estimation | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` (if exists) | `overview.md` (estimation section) |
| implementation | `brainstorm.md`, `plan.md`, `analysis.md` (fallback for simplicity gate when brainstorm skipped) | `implementation.md` (+ signals: `diff_surface`, `lines_changed`, `new_files_count`) |
| qa | `ticket.md`, `implementation.md`, `plan.md` | `qa.md` (+ signals: `tests_added`, `tests_broken`, `coverage_change`) |
| review | `ticket.md`, `review-spec.md` (generated from brainstorm AC + chosen approach), `plan.md` (if any), `qa-facts.md` (generated from qa.md evidence) | `review.md`, `review-spec.md`, `qa-facts.md` |
| local-test-analysis | `ticket.md`, `implementation.md`, `plan.md` or `brainstorm.md`, codebase | `local-test-plan.md` |
| local-test-execution | `local-test-plan.md`, `implementation.md` | `local-testing.md` |
| local-test-fix | `local-testing.md`, `local-test-plan.md`, `implementation.md` | code fixes, then re-execution |
| pr | `overview.md` (full); verdict lines only from `review.md`, `qa.md`, `local-testing.md` (skip mode: `overview.md` only); `implementation.md` by path | `overview.md` (updates) |
| ci | `overview.md`, `plan.md`, `implementation.md` | `overview.md` (CI status) |
| finish | `overview.md`; PR state via gh | `overview.md` (Finish section) |
| release | `overview.md` (optional, for merge SHA); `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` | tracker comment (best-effort) |
| investigation-deliverable | `ticket.md`, `analysis.md`, `brainstorm.md` | `investigation.md` |


## Tracker Routing

Tracker MCP tool names are never hardcoded — they're resolved at runtime from `$N1_HOME/config.json` operations map. The `tracker.type` field (`"jira"` or `"youtrack"`) controls conditional branching (parameter shapes, cloudId resolution); the `tracker.mcp` field (e.g., `"jira-velosity"`, `"youtrack"`) controls MCP tool call prefix construction (`mcp__<tracker.mcp>__<operation>`). Two presets exist:

| Tracker | type | mcp value | Key operations |
|---------|------|-----------|---------------|
| Jira | `jira` | `plugin_atlassian_atlassian` | `getJiraIssue`, `transitionJiraIssue`, `addCommentToJiraIssue`, `getTransitionsForJiraIssue`, `atlassianUserInfo` (getCurrentUser), `editJiraIssue` (assign, editTicket) |
| YouTrack | `youtrack` | `youtrack` | `get_issue`, `update_issue` (moveStatus, editTicket), `add_issue_comment`, `get_issue_comments`, `get_current_user` (getCurrentUser), `change_issue_assignee` (assign) |

When `ticketTagging.enabled` is true, `n1-start` prefixes created tickets with `ticketTagging.service` (`{service} | title`) and adds a `**Service:**` line to the description. Off by default; configured by `n1-init`. Creation only — existing tickets are never re-tagged.

When `tracker.assignToCreator` is not `false` (default ON), `n1-start` assigns tickets it creates to the currently-authenticated tracker user via the `getCurrentUser` + `assign` operations. Creation only; non-fatal on failure; silently skipped when those operations are absent (legacy configs). Configured by `n1-init`.

On brain-dump/file runs where the user opts to create a ticket, `n1-start` adopts the **created ticket ID** as the per-ticket memory `<ID>` and worktree name. An ID-Final invariant blocks any memory/worktree write until that ID is known; if state was already written under the provisional slug, the idempotent `Reconcile Memory ID & Branch` procedure moves the memory folder (inside `$N1_HOME/memory/`) and renames the worktree directory to the ticket-ID-based names.

## Type Registry

Workflow types are declared in `pipeline.json` under `types`. Each type defines its step sequence, detection rules, and optional per-step model overrides.

| Type | Steps | Detection | Key differences |
|------|-------|-----------|-----------------|
| `task` (default) | ticket → analysis → [brainstorm] → [plan] → [plan-review] → [estimation] → implementation → qa → review ⇄ fix → [local-testing] → pr → [ci] → [finish] → [release] | `detect.default: true` | Full pipeline |
| `investigation` | ticket → analysis → brainstorm → investigation-deliverable | tags: `investigation` (title hint only) | No implementation, QA, or PR. Interactive Q&A during analysis + deliverable, tracker enrichment, post-investigation routing (create/convert/close) |
| `bug` | ticket → analysis → [brainstorm] → [plan] → implementation → qa → review ⇄ fix → [local-testing] → pr → [ci] → [finish] → [release] | Type field: `bug`, tags: `bug` | Brainstorm/plan signal-gated: skipped when root cause known + blast radius not high + files < 5; analysis model downgraded |
| `chore` | ticket → analysis → implementation → qa → review → pr → [ci] → [finish] → [release] | Type field: `chore`, tags: `chore/config/deps` | Skips brainstorm, plan, local-testing; analysis and review models downgraded |

Brackets = skippable by config gates or runtime signals. Detection cascade: `--type` flag > tags > type_field > default.

The winning rule is stored as `type_matched_by` in overview.md frontmatter; a project where most tickets resolve by `default` has a tracker-hygiene problem, not a routing one.

Adding a new type requires only a `types` entry in `pipeline.json` — no new skills, step files, or orchestrator code changes.

## Runtime Signals

Steps emit runtime signals stored as `<!-- n1:signals -->` blocks in memory files. Signals drive step gating, model tiering, and decision telemetry.

| Step | Signals | Stored in |
|------|---------|-----------|
| ticket | `task_type`, `has_acceptance_criteria`, `description_quality` | ticket.md |
| analysis | `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause`, `self_resolved` | analysis.md |
| brainstorm | `planning_need`, `design_clarity`, `approach_count`, `files_changed`, `blast_radius` | brainstorm.md |
| implementation | `diff_surface`, `lines_changed`, `new_files_count` | implementation.md |
| qa | `tests_added`, `tests_broken`, `coverage_change` | qa.md |
| investigation-deliverable | `confidence`, `implementable`, `unknowns_resolved`, `findings_count`, `recommendations_count`, `self_resolved` | investigation.md |

Helpers in `lib/signals.sh`: `n1_read_signal`, `n1_write_signals`, `n1_eval_signal_gate`.

## Model Tiering

`n1_resolve_model` accepts an optional context parameter for signal-driven model selection. Resolution chain: config override > signal-driven triggers (condition-gated, escalation before downgrade) > profile step_overrides > agent frontmatter default. Tier keywords: `frontier` (opus), `standard` (agent default), `downgrade` (one tier below), `minimal` (haiku). Triggers defined in `pipeline.json` under `escalation_triggers` and `downgrade_triggers` — each trigger's `.condition` is evaluated via `n1_eval_signal_gate`; the trigger fires only when its condition holds (or unconditionally if no condition is specified). When the same key appears in both sections, escalation is checked first. The `developer:implementation` step has an escalation trigger that promotes to frontier when `analysis.blast_radius` is `high` or `analysis.security_relevant` is `true`.

## Memory Compaction

`n1_compact_memory` in `lib/memory.sh` archives full memory files to `<file>.full.md` and replaces originals with compacted versions keeping only high-signal sections. Applied after brainstorm (291K → <10K target), analysis (30-50% reduction), and implementation before review (40-60% reduction).

## Analysis Cache

Project-level snapshot that eliminates redundant codebase discovery on sequential tickets. Gated on `analysisCache.enabled` in `$N1_HOME/config.json` (default `true`).

**Snapshot location:** `$N1_HOME/cache/project-snapshot.md` — structured, schema-versioned document with provenance comments per section. Not a memory file — it's a cache artifact scoped to the project, not a ticket.

**Lifecycle:** First ticket (cold start) generates the snapshot as a byproduct of full analysis. Subsequent tickets (warm start) inject it into the solution-architect's prompt, skipping project-level discovery. Stale snapshots trigger full regeneration.

**Invalidation (full-snapshot, v1):** git-diff-based classification against `analysisCache.structuralFiles` (force stale), neutral-file threshold (`analysisCache.neutralThreshold`, default 15), and TTL (`analysisCache.ttl`, default `"4h"`). Provenance comments stored per section for future partial invalidation.

**Fail-open:** Any cache failure (corrupt file, missing SHA, git error) falls back to full analysis. `SNAPSHOT_DRIFT` markers from the agent force regeneration on the next ticket.

**Helpers:** `lib/cache.sh` — `n1_snapshot_path`, `n1_snapshot_check_freshness`, `n1_snapshot_read_body`, `n1_snapshot_write`, `n1_parse_ttl`.

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `analysisCache.enabled` | boolean | `true` | Master gate |
| `analysisCache.ttl` | string | `"4h"` | Max age before forced regeneration |
| `analysisCache.neutralThreshold` | integer | `15` | NEUTRAL files changed before invalidation |
| `analysisCache.structuralFiles` | string[] | See `defaults/analysis-cache.json` | Glob patterns for structural files |

## Cross-Repo Awareness

Optional feature for exploring related projects' code during analysis and investigation. Gated on `relatedProjects.enabled` in `$N1_HOME/config.json` (default `false`).

**Project Map:** `$N1_HOME/cache/project-map.md` — lightweight structural index (~300-500 tokens) of a project's navigable surface: modules, API surface, exports, integration points, key files. Generated by the solution-architect as a piggyback during analysis (same lifecycle as project-snapshot.md). Used by cross-repo consumers to navigate related codebases without blind exploration.

**Related Projects:** `relatedProjects.projects[]` in config — registry of cross-repo relationships. Each entry has `slug` (maps to `~/.n1/<slug>/`), `reason` (relevance hint), `source` (`"auto"` or `"manual"`), `confirmedAt`. Resolution: slug → peer config → `repoPath` + project map.

**Auto-discovery (during analysis):** The solution-architect emits `XREPO_SUGGEST: <slug> <reason>` lines for projects it discovers (incremental — skips already-confirmed projects). The orchestrator auto-adds via `n1_related_add` in hands-off mode, or — in interactive mode — persists the suggestions to `$N1_HOME/memory/<ID>/xrepo-pending.tsv` (skill Bash blocks are separate invocations, so shell variables cannot carry state across the prompt) and asks the user yes/no/select. Approved slugs are added via `n1_related_add` and recorded as `[asked]` Decision Ledger rows. No confidence tiering; no CLAUDE.md reading.

**Auto-discovery (during `n1-init`):** Three-tier confidence cascade — high (direct import/require in file contents, `.proto`/`.graphql` refs) → auto-add with `source:"auto"`; medium (yaml/yml/env references) → read the candidate's CLAUDE.md, present to the user for confirmation; user choosing "Add all" records entries with `source:"auto"`, explicit per-entry confirmation records `source:"manual"`; low → skip.

**Runtime detection:** Post-implementation diff scan (`n1_related_detect_in_diff`) detects unregistered cross-repo references; the current project is always excluded, and slug/service matching is literal (metacharacters escaped) with non-alphanumeric boundaries. Detections are persisted to `$N1_HOME/memory/<ID>/xrepo-runtime.tsv` so the prompt response (a later Bash invocation) can act on them. In hands-off mode, auto-adds to config. In interactive mode, presents suggestion. The review step injects the registered related projects list into the code-reviewer prompt, which flags unregistered cross-service calls as advisory `[XREPO-N]` findings (non-blocking).

**Pipeline touchpoints:**

| Step | Cross-repo behavior |
|------|-------------------|
| Analysis | Auto-discovery + exploration. SA reads project maps and code from related repos. |
| Investigation | Same as analysis — traces bugs across service boundaries. |
| Implementation | Post-impl diff scan for runtime detection. |
| Review | `[XREPO-N]` advisory findings for unregistered cross-service calls. |

**Freshness:** Local project map follows analysis cache lifecycle (regenerated on cold/stale). Cross-repo consumers use `relatedProjects.maxSnapshotAge` (default `"72h"`, TTL-only — no git-diff for remote repos).

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `relatedProjects.enabled` | boolean | `false` | Master gate |
| `relatedProjects.maxSnapshotAge` | string | `"72h"` | Cross-repo map freshness threshold |
| `relatedProjects.projects[].slug` | string | — | Maps to `~/.n1/<slug>/` |
| `relatedProjects.projects[].reason` | string | — | Why related (relevance filter) |
| `relatedProjects.projects[].source` | string | — | `"auto"` or `"manual"` |
| `relatedProjects.projects[].confirmedAt` | string | — | ISO timestamp |

**Helpers:** `lib/related.sh` — `n1_project_map_path`, `n1_project_map_check_freshness`, `n1_related_projects`, `n1_related_project_map`, `n1_related_detect_in_diff`, `n1_related_add`, `n1_related_escape_ere`.

**Telemetry fields** (emitted on step events via `n1_emit_step_event`):

| Step | Field | Type | Description |
|------|-------|------|-------------|
| Analysis | `cross_repo_explored` | boolean | `true` if any related project's code was read |
| Analysis | `cross_repo_projects` | string | Comma-separated slugs of explored projects |
| Analysis | `cross_repo_maps_generated` | integer | On-demand cold-start maps generated |
| Analysis | `cross_repo_discovery_new` | integer | Newly discovered relationships |
| Implementation | `cross_repo_runtime_detected` | string | Slugs detected in diff but not in relatedProjects |
| Implementation | `cross_repo_runtime_added` | string | Slugs auto-added (hands-off) or confirmed (interactive) |
| Review | `cross_repo_xrepo_findings` | integer | Count of `[XREPO-N]` advisory findings |

Note: when `relatedProjects.enabled` is `true`, the analysis step self-emits its completed step event carrying the four analysis fields (and the orchestrator does not emit a second one); when the feature is off, the orchestrator emits the standard analysis end event. Implementation and review fields are merged into their respective step-end events (not self-emitted by the agent).

## Rules Layer

Authored, checkable project conventions stored as `.rule.md` files with YAML frontmatter (`description`, `topic`, `applies_to`, `enforcement`, `paths`). Two enforcement rungs:

- **`gate`** — rule is injected into reviewer prompts; violation produces a `[RULE-N]` finding that causes review FAIL. Also checked during plan-review CCR.
- **`deny`** — generates a PreToolUse hook that deterministically blocks matching tool calls. Registered in `.claude/settings.local.json` (not in plugin `hooks/hooks.json`).

Rules always live in `$N1_HOME/rules/`. Deny hooks are generated at `$N1_HOME/hooks/rules-deny.sh`. Rules are injected into agent prompts at every spawn via `lib/rules.sh` helpers — filtered by `applies_to` persona and `paths` intersection with the ticket's change surface.

Relationship to analysis cache: the snapshot carries descriptive content (how the project IS); rules carry prescriptive content (how the project MUST BE). Where they conflict, rules win — stated explicitly in the analysis step prompt. `lib/cache.sh` uses mtime-based staleness to detect rule edits outside the git tree.

**Helpers** in `lib/rules.sh`: `n1_rules_dir`, `n1_rules_list`, `n1_rule_field`, `n1_rule_body`, `n1_rules_for_agent`, `n1_rules_render`, `n1_rules_deny_field`, `n1_generate_deny_hook`, `n1_deny_hook_register`, `n1_deny_hook_deregister`.

## Implementation Simplicity Gate

When `tier == simple` AND `blast_radius == low` AND `files_changed < 3`, the implementation step bypasses SDD fan-out and spawns a single developer agent directly. Fallback to full SDD if the developer fails. Gate checked before the existing planning_need routing. Signals are read from `brainstorm.md` first (post-design, scope-aware); falls back to `analysis.md` when brainstorm was skipped.

## Lite-Analysis Gate

When `tier == simple` AND `description_quality` is `adequate` or `weak` AND `type` is `task` or `chore`, the analysis step runs the solution-architect with reduced scope. All three inputs exist before analysis runs: `tier` and `type` from `overview.md` frontmatter, `description_quality` from the `ticket.md` signal block.

The analysis step **produces** the signals downstream gates consume, so it can never be skipped. Lite mode changes how much work produces the signals, not the signals themselves — the architect's Output Contract (`n1:signals` line, `tier:` line, `context:` block) is identical in both modes.

**Stripped in lite mode:** industry-standards web research, cross-repo exploration (the `relatedProjects` block is skipped entirely, including peer-map freshness checks), observability enrichment, snapshot persistence, and project-map generation. The codebase scan narrows to the files the ticket touches, and the report is capped at 300 words.

**Not stripped:** the model. `pipeline.json` already downgrades `solution-architect:analysis` to Sonnet on adequate descriptions; lite mode keeps that tier because codebase verification is the safety net. Savings come from scope, not capability.

**Escape hatch:** if the architect finds the task touches 3+ files, spans modules, touches auth/crypto/secrets/input-validation, changes a public API, or changes a schema or contract, it abandons the lite budget, emits corrected signals, and returns `LITE_ESCALATED: <reason>`. The orchestrator logs it to `## Key Decisions` and continues — analysis is never re-run. The corrected signals then drive the existing `pipeline.json` escalation triggers.

**Cache interaction:** a lite run writes no snapshot, so a cold cache stays cold and the next standard-tier ticket warms it. A `fresh` snapshot is still consumed — that path already skips project discovery and composes with lite's other reductions.

**Telemetry:** the decision is recorded as `lite-analysis-gate` on both outcomes via `n1_record_decision`, so `/n1:n1-telemetry` can correlate lite runs against review pass rate, fix cycles, and `LITE_ESCALATED` frequency. A high escalation rate means the gate is too loose. No config key — the gate is purely signal-driven, like the Implementation Simplicity Gate.

## Ticket Description Enrichment

Optional two-phase enrichment that writes structured content back to the tracker when a ticket description is poor or absent. Gated on `ticketEnrichment.enabled` (default true) and the `editTicket` operation existing in config.

- **Phase 1** (product-analyst, Step 1): quality assessment (Empty / Skeletal / Weak / Adequate) → silent append for empty/skeletal descriptions, silent rewrite for weak descriptions. Idempotency markers: `*Structured by N1*` / `*Restructured by N1*`.
- **Phase 2** (orchestrator, after Step 3 Brainstorm): appends refined acceptance criteria and scope boundaries to description, posts a design summary comment. Idempotency marker: `*Refined after design review — N1*`.

Both phases are non-blocking — MCP failures are logged and skipped. Freshly created tickets (brain-dump/file/error-tracker modes) skip Phase 1 (adequate by construction).

## Estimation

Optional complexity classification and delivery time estimation. Gated on `estimation.enabled` (default false) in `$N1_HOME/config.json`. When enabled, the orchestrator classifies task complexity into tiers (XS/S/M/L/XL), maps to a configurable time estimate, and writes results to overview.md + tracker ticket (description append + time field).

- **Pipeline integration:** after plan when `planning_need: plan` (Step 4c), after planning need routing when `planning_need: direct`. Uses the best available context — plan.md when present, brainstorm.md otherwise.
- **Standalone:** `n1-estimate` skill runs Steps 1–3 (ticket → analysis → brainstorm) then estimates. No implementation, no branch creation, no status transitions.
- **Default mapping** in `defaults/estimation.json`: XS=30m, S=2h, M=6h, L=2d, XL=5d. Overridable per-project via `estimation.mapping` in config (partial overrides merge with defaults).
- **Tracker writes:** Jira `originalEstimate` via `editJiraIssue`, YouTrack `Estimation` field via `update_issue`. Both non-blocking. Idempotency marker: `*Estimated by N1*`.

## Local Testing

When `localTesting.enabled` is true, n1-start runs a local verification phase (Step 9) after Review and before PR. Behavior depends on `localTesting.mode` (configured by `n1-init`, or inferred: startCommand present -> `"live"`, absent -> `"test"`):

- **`"live"`** (default when startCommand is configured): The local-test-planner discovers infrastructure, app startup (auto-detected or via `localTesting.startCommand` config override), and existing e2e test suites. Execution runs existing e2e tests first, then generates ad-hoc curl/CLI scenarios only for acceptance criteria not covered by the e2e suite. Enforces Runtime First mandate (NP-78).
- **`"test"`** (default when no startCommand): Runs existing test suites only with no infrastructure startup. The planner suppresses Runtime First and produces test-suite-only plans.
- **`"smoke"`** (cloud-native services): Skips the local-testing step entirely with `smoke_deferred` telemetry. After merge and deployment, n1-finish runs post-deploy verification (health endpoint check via `localTesting.smokeEndpoint`, custom commands via `localTesting.smokeTests`).

Bounded fix loop (live/test modes): `localTesting.maxFixAttempts` (default 3). Off by default; configured by `n1-init`.

Local testing owns all live-app verification -- starting services, running e2e suites, hitting real endpoints. QA owns the unit test suite. These scopes are independently defined; neither is conditional on the other being enabled.

The PR body uses a unified `## Verification` section (not separate `## Test Plan` / `## Local Testing`). The tech-writer merges QA verification steps with local testing results via best-effort semantic matching -- matched items show checked/unchecked with evidence, unmatched items from either source are included as-is.

## Test Coverage Tiers

Configurable QA behavior controlled by `testCoverage.tier` in `$N1_HOME/config.json` (default `"maintain"` when absent). QA writes **unit tests only** — testing individual functions, modules, and handlers in isolation. Integration and e2e verification belongs to the local testing step. Three tiers:

| Tier | QA behavior |
|------|-------------|
| **maintain** (default) | Run existing unit tests, fix breakage, update for changed functionality. No new tests. |
| **minimal** | Maintain + 1–3 focused unit tests per feature, acceptance-criteria-only |
| **standard** | Minimal + edge cases + error paths, capped at 10 per test file / 3 per group. Unit-level only. |

Cross-tier invariants: broken tests are always fixed, tests for removed functionality are always updated. QA never writes tests that require starting the application or making HTTP requests to a running server.

The code-reviewer evaluates a **Test Quality (TQ)** dimension with `[TQ-N]` prefix findings (Medium/Low severity, non-blocking). A TQ fix loop (Step 7b in n1-start) spawns the QA agent to fix flagged tests before the review fix loop.

**QA evidence and optional verification gate.** Each QA run writes a `### Evidence` subsection to `qa.md` containing the exact runner command, exit code, and last ~10 lines of output from the Step 6 full-suite run. Without `qa.verifyGate`, this evidence is agent-transcribed (not machine-captured). When `qa.verifyGate` is true (the default; set `false` to disable), the orchestrator re-executes the suite via Bash after the agent returns, stores the log under `$N1_HOME/memory/<ID>/qa-verify.log`, and records any exit-code mismatch in overview Key Decisions. If Evidence is absent or the fallback qa.md was written, the orchestrator sets `qa_verdict_unverified: true` in overview.md frontmatter, records a Key Decision ("QA degraded: unevidenced verdict"), and the review step instructs the code-reviewer to treat the QA pass as unconfirmed when evaluating Test Quality.

**Break-check.** After QA returns, the orchestrator verifies that tests can fail using `lib/breakcheck.sh`: non-test files are checked out from the branch point, the named test is run and must appear in the failing list (parsed by `lib/testparse.sh`), then `HEAD` is restored and the suite must be green again. Bug tickets: the `Regression test:` line in `qa.md` is mandatory and a `never-red` or `inconclusive` verdict fails QA and starts a fix cycle. Other types: each `New test:` line (up to `qa.breakCheckMaxTests`, default 5) is checked and hollow tests become non-blocking `[TQ-N]` findings for the code-reviewer. Modes via `qa.breakCheck`: `bugs` (default), `all` (blocking for every type), `off`. Verdict stored as `break_check_verdict` in overview.md frontmatter; logs under `$N1_HOME/memory/<ID>/break-check.log*`.

## Observability Integration

Optional multi-provider observability integration. Config-driven via `observability` block in `$N1_HOME/config.json`. Flat provider map: each provider is a self-contained entry with free-text `instructions` and optional `env` tag. Supports MCP tools, kubectl, CLI tools, HTTP APIs, and instructions-only providers (filesystem-based data sources). When `observability` is `null` or absent, the feature is fully disabled.

Config structure:
```json
{
  "observability": {
    "default": "prod",
    "providers": {
      "sentry": {
        "mcp": "publius-sentry",
        "env": "prod",
        "instructions": "Search Sentry for errors related to the task.",
        "operations": { "searchIssues": "search_sentry_issues" },
        "urlPattern": "sentry\\.io/issues/|my-org\\.sentry\\.io/issues/",
        "orgSlug": "my-org",
        "projectSlug": "my-backend"
      },
      "loki": {
        "mcp": "publius-prod-loki-mcp",
        "env": "prod",
        "instructions": "Query Loki for application logs.",
        "operations": { "query": "loki_query", "labelNames": "loki_label_names", "labelValues": "loki_label_values" }
      },
      "n1-telemetry": {
        "instructions": "N1 pipeline telemetry. Data at ~/.n1/<project>/memory/<ticket-id>/telemetry/."
      }
    }
  }
}
```

Each provider requires `instructions` (free-text). Optional: `env` (ties to environment — global providers with no `env` are always active), `mcp` (MCP server name), `operations` (operation map), `context` (kube context), `urlPattern`, `orgSlug`, `projectSlug`.

Provider activation: global providers (no `env`) always active; env-tagged providers active when `env` matches `observability.default`.

Three pipeline touchpoints:
- **Intake** (n1-start + product-analyst): providers with `urlPattern` field (e.g. Sentry) support direct URL intake — URL detection, MCP fetch of issue data, structured `ticket.md`. Intake fields (`urlPattern`, `orgSlug`, `projectSlug`) live on the provider entry alongside `mcp` and `operations`.
- **Analysis — error-tracker tasks:** all active providers get their instructions and operations granted to the solution-architect; agent searches errors, queries logs, and checks traces
- **Analysis — bug tasks:** same grants with a lighter directive

On-demand access is automatic via session-start OBSERVABILITY ROUTING injection — no pipeline changes needed for ad-hoc queries. MCP providers show their tool prefix and operations; instructions-only providers inject their full instructions text. Adding a new provider requires zero code changes — just a config entry.

## Finish Work

Optional final pipeline step (`finish`) that runs after CI, gated on `finishWork.enabled` (default `false`) in `$N1_HOME/config.json`. The standalone `/n1:n1-finish` skill works regardless of the gate — it's a merge-verify + close command any time. The ticket is closed **only when the code is actually merged**, never on green-CI-but-open.

- **Merge:** `mergeOnFinish` (default `false`, reviewer merges) triggers `gh pr merge --auto --<mergeMethod> --delete-branch` when enabled.
- **Deploy watch** (`deployWatch.enabled`, default `false`): polls `gh run list --commit <sha>` for workflow runs on the merge commit, optionally filtered by `workflowName`. Deploy failure leaves the ticket open.
- **Ticket close:** requires `tracker.statuses.done` in config (detected by `n1-init`, or added manually); absent → finish skips closing with an explanatory message.

## Release

Optional final pipeline step (`release`) that runs after finish, gated on `release.enabled` (default `false`) in `$N1_HOME/config.json`. The standalone `/n1:n1-release` skill works regardless of the gate.

Two modes: built-in gh flow (`procedure: null`) creates an annotated git tag and GitHub Release via `gh release create --generate-notes`; custom flow (`procedure: "<markdown>"`) walks the user through a pasted markdown procedure with placeholder substitution (`{{RELEASE_TAG}}`, `{{VERSION}}`, `{{MERGE_SHA}}`, `{{TICKET_ID}}`).

Idempotent: `gh release view` check before creating; existing tag/release causes a skip. Tracker comment ("Released as vX.Y.Z") posted best-effort when a ticket can be inferred from the branch name.

Config keys: `release.enabled` (boolean, default `false`), `release.tagPrefix` (string, default `"v"`), `release.procedure` (string|null, default `null`), `release.draft` (boolean, default `false`).

## Agent Personas

12 atomic agents with scoped tools and configurable models:

| Agent | Default Model | Effort | Tools | Pipeline Stage |
|-------|---------------|--------|-------|----------------|
| product-analyst | sonnet | low | inherits (needs dynamic tracker + error-tracking MCP) | Ticket read, Error intake, Description enrichment |
| solution-architect | opus | medium | Read, Grep, Glob, Bash, WebSearch, WebFetch | Analysis, Bug investigation, Plan review (CCR) |
| planner | opus | medium | Read, Grep, Glob, Write, Edit, Skill, WebSearch, WebFetch | Plan writing |
| implementer | sonnet | medium | inherits (needs Skill for SDD, Agent for SDD subagents) | Implementation (wraps SDD) |
| developer | sonnet | medium | Read, Edit, Write, Bash, Grep, Glob | Fix cycle, CI fix |
| code-reviewer | opus | medium | Read, Grep, Glob | Review (parallel) |
| security-reviewer | opus | medium | Read, Grep, Glob | Review (parallel) |
| qa-engineer | sonnet | medium | Read, Edit, Write, Bash, Grep, Glob | QA (tier-aware: maintain/minimal/standard) |
| intake-agent | haiku | low | Read, Grep, Glob, Bash | Ticket/content intake |
| local-test-planner | sonnet | medium | Read, Grep, Glob, Bash | Local testing (plan creation) |
| tech-writer | sonnet | medium | Read, Grep, Edit, Write, Glob | Doc update, PR content |

Models default to agent frontmatter values, overridable via `models` section in `$N1_HOME/config.json`.

Agent effort levels are static per-agent, set via subagent frontmatter `effort:` field (low or medium). Session-level effort (`/effort`, `effortLevel` setting) controls the orchestrator's reasoning depth — it does not propagate to subagents. There is no per-spawn effort parameter.

**Cold review.** The code-reviewer never receives `implementation.md` or `brainstorm.md`; it reads a generated `review-spec.md` (acceptance criteria and chosen approach) and derives the change surface from the diff. The orchestrator snapshots the working tree before spawning reviewers (`lib/treestate.sh`) and discards the pass if the tree moved. Every acceptance criterion gets a row in the reviewer's `### AC Coverage` table; a missing criterion is a High finding, and the tech-writer copies the table into the PR body.

Note: Sonnet 4.6 supports effort levels low, medium, high, and max (no xhigh).

**Trusted web research (always on).** `solution-architect` and `planner` carry `WebSearch, WebFetch` to research industry standards, best practices, and practitioner experience during analysis, planning, and plan-review. Research is constrained by the shared rubric in `agents/research-standards.md`: trusted source tiers, a marketing reject-list, ≥2-source corroboration, mandatory URL citation, a standards-over-soft-practices fitness gate (guards against over-engineering), and graceful degradation when the network is unavailable. Library API docs still go through Context7, not web search.
- **Single-pass analysis & research (v2.11.0):** the pre-plan `solution-architect` "deeper analysis" re-spawn was removed — the Step-2 `analysis.md` plus the `planner`'s native file discovery feed planning, and plan-review (4b) is the assumption safety net. Web research runs once (Step 2); 4b validates against the standards already recorded in `analysis.md` rather than re-researching.

## Session Start Hook

`hooks/session-start.sh` fires on session start/resume/clear/compact. It resolves `N1_HOME` via `n1_home()` from `lib/config.sh` (env var → auto-derive from repo name → legacy git config → in-repo `.n1/`), then reads `$N1_HOME/config.json` and injects context telling Claude to prefer N1 skills. When a tracker is configured, it also injects a **TRACKER ROUTING** directive containing the tracker type, MCP server name, full operations map, and a negative instruction to never use any other MCP server. This keeps the correct MCP server name in the model's attention window throughout the session. After running `n1-init`, the user must `/clear` or restart to pick up the new config.

## Escalation Model

Fixed checkpoints: after PR creation (Tech Lead reviews). Plan checkpoint is off by default (`requirePlanApproval: false`) — the plan-review CCR step validates the plan automatically. Enable `requirePlanApproval: true` to restore the manual plan checkpoint.
Confidence-based: low confidence + high blast radius = stop and ask.
Always escalate: security, architecture, public API changes.

## Autonomy

### `autonomy` block

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `mode` | `hands-off` \| `interactive` | `hands-off` (unset) | Single key controlling all autonomy behavior. `hands-off`: all mechanical prompts auto-resolve, brainstorm runs autonomously, acceptance gate auto-confirms. `interactive`: pipeline asks at every decision point. |

Legacy keys (`brainstorm`, `mechanicalPrompts`, `qualityEscalations`, `tailChain`, `acceptanceGate`, `escalationMargin`) are still accepted as a backward-compat fallback when `mode` is absent. A deprecation note is emitted at session start.

**Unconditional gates** (never affected by `autonomy.mode`): security/architecture/public-API escalations, release confirmation, prod deploys, secrets. These are configured in the `escalation.alwaysAskOn` array.

Every autonomous decision appends a row to the `## Decision Ledger` table in overview.md (spec: `skills/n1-start/ledger.md`); the ledger uses a 9-column format (step, category, tier, tag, question, chosen, alternatives, reason, rungs_tried — the 9th column added in v2.90.0). The tech-writer renders it as a `## Decisions` section in the PR body — the after-the-fact review artifact. Hard invariants: security/architecture/public-API escalations always block; **release is never automatic** — `tailChain` scope ends at finish, release is declared `manual_only` in `pipeline.json`, and the n1-release confirmation gate is unconditional.

Cross-session resume: the pr step writes a `## Pending` block (`awaiting: merge`) to overview.md; `hooks/session-start.sh` scans these (capped at 5 `gh pr view` calls, 30-min throttle via `last_checked`, 14-day expiry, fail-open) and suggests `/n1:n1-finish` when the PR was merged externally.

## Story Orchestration

`/n1:n1-story-run <STORY-ID>` (also reached when `/n1:n1-start` is given a Story/Epic or a parent with subtasks) runs every open subtask through `n1-start` sequentially. Each subtask runs as a **headless child process** launched from the subtask's repository: `cd <repoPath> && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STORY_ID=<STORY> claude -p "/n1:n1-start <ID>" --model <sonnet|opus> --permission-mode bypassPermissions`. The repo is found by matching the subtask's `service | title` prefix against `ticketTagging.service` in `~/.n1/*/config.json` and reading that config's `repoPath` (written by n1-init). A dependent subtask starts only after its predecessor's PR is merged; the orchestrator polls `gh pr view` and runs a headless `n1-finish` on merge.

Env contract: `N1_AUTONOMY_PRESET=autonomous` makes `n1_autonomy_val` return the fully autonomous profile (`brainstorm=auto`, `mechanicalPrompts=auto`, `qualityEscalations=auto-accept`, `tailChain=suggest`, `acceptanceGate=auto`, `escalationMargin=0.05`) and disables the plan checkpoint. `N1_HEADLESS=1` turns any remaining prompt into a recorded escalation (`## Escalations`, `step: escalated`) and ends the child. `N1_STORY_ID` is recorded in the child's overview frontmatter. `N1_STORY_PLUGIN_DIR` (optional) passes `--plugin-dir` to each child `claude -p` invocation, allowing story runs against a local plugin build.

Model per subtask: sonnet by default; opus when size ≥ `story.opusFromSize` (default M) or a risk flag (`security`, `public-api`, `schema-migration`, `contract`) is set. Outcomes read from the child's overview.md: `merged`, `awaiting-merge`, `escalated`, `failed`. Any escalation pauses the story (comment on the story, `step: paused`); re-running the command resumes. On completion a `N1 Story Summary` comment is posted grouped by service with PR links. Helpers: `lib/story.sh`; defaults: `defaults/story.json`. Release remains manual.
