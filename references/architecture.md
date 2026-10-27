# N1 Architecture Reference

## Orchestration Pattern

Skills are lightweight controllers that delegate all heavy work:

| N1 Skill | Delegates To | Purpose |
|----------|-------------|---------|
| n1-start | product-analyst, solution-architect, planner, implementer, qa-engineer agents + n1-brainstorm, n1-plan | Full pipeline. Brainstorm step uses brainstormer agent when `BRAINSTORM_MODE` is `auto`; n1-brainstorm in interactive mode (interactive investigation runs in n1-refine). Implementation uses an implementer agent wrapping n1-implement. |
| n1-review | code-reviewer, security-reviewer, developer agents | Review + fix loop |
| n1-pr | tech-writer agent + inline git/gh/MCP | Doc update, push, create PR, update tracker |
| n1-ci | developer agent + inline gh CLI | Post-PR CI watch, classify failures, fix loop |
| n1-finish | (inline: gh + tracker MCP) | Merge verify, deploy watch, ticket close, worktree cleanup |
| n1-release | (inline: gh + git + tracker MCP) | Git tag, GitHub Release (or custom procedure), tracker comment |
| n1-init | (inline: analysis + prompts) | Project setup wizard (v2: migration flow) |
| n1-clean | (inline: git worktree remove) | Worktree cleanup for abandoned or completed tickets |
| n1-ticket | solution-architect agent + inline context capture, web research, tracker MCP | Create a single backlog ticket (Task/Bug) from conversation context |
| n1-story | solution-architect agent + inline context capture, interactive discovery, tracker MCP | Create a story with subtask tickets from conversation context |
| n1-refine | product-analyst, solution-architect agents + inline decision loop, tracker MCP | Settle a ticket's decisions, scope, AC and assumptions with the user before the pipeline; writes one `*Refined by N1*` block (or a comment on another person's ticket); hosts interactive `--investigate` |
| n1-queue | headless child per ticket (`n1_headless_cmd`: `claude -p`) (n1-start), tracker MCP | Run a batch of tickets (by tag or story subtasks) through the pipeline sequentially without merging; background runner |
| n1-rules | (inline: lib/rules.sh) | List, add, validate project rules; regenerate deny hook |

Agent spawns use N1's own agent definitions. Each gets fresh context — the orchestrator never accumulates full history.

`git.prMode` (`$N1_HOME/config.json`) controls how a branch reaches `main`: `"draft"` and `"ready"` go through n1-pr (push + PR create); `"skip"` bypasses n1-pr and n1-ci entirely and has n1-finish merge the branch to `main` locally (no auto-push).

## Investigation Mode

When a ticket matches a type's detection rules in the `pipeline.json` type registry (tags or type field, or an explicit `--type` flag; titles never route — a title that reads like an investigation only prints a hint), N1 runs that type's step sequence. The `investigation` type runs a shortened pipeline: ticket -> analysis -> brainstorm -> investigation-deliverable. The deliverable is a structured findings/recommendations/metrics document written to `investigation.md` with signals (`confidence`, `implementable`, `unknowns_resolved`, `findings_count`, `recommendations_count`, `validation_confidence`). Implementation, QA, review, and PR steps are skipped. During analysis and deliverable production, the agent classifies unknowns into A/B/C tiers (matching the brainstormer pattern): A-tier (human-only) are flagged via `<!-- n1:unknown -->` markers and presented to the user; B-tier (code-answerable) are self-resolved via codebase exploration and marked with `<!-- n1:resolved -->`. Only A-tier unknowns reach the user Q&A phase. After the deliverable, tracker enrichment writes findings back to the ticket (description append + comment), and post-investigation routing offers three options: create a new linked implementation ticket, convert the current ticket to implementation, or close. Under a queue run (`N1_QUEUE_RUN_ID` set), both the Phase 4 discussion wait and the interactive Phase 5 menu are skipped: tracker enrichment runs unconditionally regardless of `ticketEnrichment.enabled`, and post-investigation routing is forced to restore-only — the ticket is moved back to its captured original status (or left as-is if none was captured), with no follow-up ticket, conversion, or close. Interactive investigation runs in `/n1:n1-refine <ID> --investigate`, which runs this step in its caller mode and continues into the refine decision loop when the result is implementable. Interactive n1-start on an investigation-typed ticket stops and points there; queue and headless runs keep the n1-start path. n1-start rejects `--investigate`. Converting to implementation rewrites overview.md frontmatter (`type: task`, `step: brainstorm`, `planning_need: direct`) and the progress checklist, then offers to continue in-session — if yes, skips directly to Planning Need Routing (investigation served as brainstorm; `planning_need` is read from overview.md frontmatter, not brainstorm.md) — or resume later via `/n1:n1-start <ID>`.

Detection happens in the orchestrator after the ticket step via `n1_resolve_type()` (detection cascade: `--type` flag > tags > type_field > default). The resolved type is stored as `type: <name>` in overview.md frontmatter; the winning rule is stored as `type_matched_by` in overview.md frontmatter. A project where most tickets resolve by `default` has a tracker-hygiene problem, not a routing one. Backward compat: if overview.md has `mode` but no `type`, `n1_read_type()` reads `mode` as `type`. Post-investigation routing (create linked ticket, convert to implementation, or close) is handled in the investigation-deliverable step. Tracker enrichment (description append + comment) runs unconditionally.

## Ticket & Story Creation

`/n1:n1-ticket` and `/n1:n1-story` create backlog tickets from conversation context and/or a brain dump argument. Both are single-file skills with no persistent memory — the tracker is the source of truth.

- **n1-ticket:** Captures context → light analysis (solution-architect, low effort) → optional web research → bug type detection → approval gate → creates one Task or Bug ticket.
- **n1-story:** Captures context → deeper analysis (solution-architect, standard effort) → interactive discovery of unknowns → designs subtask decomposition (existing ticket keys can be adopted as sub-tasks) → approval gate → creates a Story ticket with linked subtasks and converts adopted tickets under it in one `jcm_convertIssueType` call (Jira with jc-mcp >= 0.9.0).

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

**Workspace isolation:** `n1-start` always works in a worktree. When an external worktree is detected (linked git worktree not under `.claude/worktrees/`), N1 skips worktree and branch creation and operates on the current checkout and branch. Otherwise it creates a git worktree at `<main-checkout>/.claude/worktrees/<ID>/` via `Ensure Worktree`. After a successful finish, `n1-finish` (`n1_finish_cleanup` in `lib/config.sh`) removes the worktree first, then deletes the local branch (`git branch -d`; `-D` only when the tip equals the merged PR's `headRefOid`). N1-managed worktrees are removed forced; external worktrees only when clean (including ignored files) and HEAD is in the merged result, never forced; otherwise they are kept with the reason in the `Cleanup:` line. Abandoned N1-managed worktrees can be removed via `/n1:n1-clean`.

**Same-ticket busy guard:** resuming an in-progress ticket calls `n1_busy_guard` (`lib/frontmatter.sh`) against overview.md's `pid` field, mirroring the queue runner's busy guard (see `scripts/n1-queue-run.sh <queue.md>` above). No pid, a dead pid, or a live pid equal to the current process (post-compaction resume) all proceed silently and (re)write the current pid; a live pid belonging to a different process warns and continues interactively, or exits 3 under `N1_HEADLESS=1`.

**Ticket-ID reuse guard:** when `n1-start` resume finds existing memory for the ticket ID with `step: done`, `n1_memory_reuse_check` (`lib/memory.sh`) checks what share of the freshly fetched tracker title's words (3+ chars) appear in the stored ticket.md (fallback: overview.md H1); at least 0.6 means related, and an empty title fails open as related. Below the threshold, the memory dir is archived to `<ID>-old` (`-old-2`, ... first free slot, capped at 50) and the run starts fresh instead of resuming stale state; in-progress memory (`step` != `done`) is never touched. `n1-start`'s resume path additionally calls `n1_archive_stale_branch` to rename (never delete) any leftover `<ID>` branch/worktree before continuing, so the new ticket's work never gets seeded with the old ticket's commits. `hooks/session-start.sh`'s pending-merge scan skips archived `<ID>-old[-N]` dirs.

**Worktree config options** (in `$N1_HOME/config.json`):
- `worktree.setup` — command to install dependencies in a worktree. Derived silently by `n1-init` from lockfiles (override for non-standard projects). Runs **lazily on first code-executing step** (implementation, or qa/review/local-testing on a resumed run), not at worktree creation — marker-guarded so it runs at most once per worktree.
- `worktree.copyFiles` — array of relative file paths (e.g. `[".env"]`) copied from the main checkout into a newly created worktree by `Ensure Worktree` (`n1_copy_worktree_files` in `lib/config.sh`). A file is copied only when the destination is missing and the path is git-ignored in the worktree, so copied files are never committed. Absolute paths and `..` segments are rejected; missing sources are skipped. Default: none.

Each step reads ONLY its declared dependencies:

| Step | Reads | Writes |
|------|-------|--------|
| ticket | — | `ticket.md` (+ `<!-- n1:signals -->` block: `task_type`, `has_acceptance_criteria`, `description_quality`). For tracker tickets: parent context (`### Parent Context`) appended when the ticket has a parent; current ticket's non-parent links (`### Linked Tickets`) appended when qualifying links exist (blockers, relates-to, depends-on). |
| analysis | `ticket.md` | `analysis.md` (+ signals: `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause`, `ticket_contradictions`) |
| brainstorm | `ticket.md`, `analysis.md`, `investigation.md` (optional) | `brainstorm.md` (+ signals: `planning_need`, `design_clarity`, `approach_count`) |
| plan | `ticket.md`, `brainstorm.md`, `analysis.md` | `plan.md` |
| plan-review | `ticket.md`, `analysis.md`, `brainstorm.md`, `plan.md` | `plan.md` (in-place fixes) |
| implementation | `brainstorm.md`, `plan.md`, `analysis.md` | `implementation.md` (+ signals: `diff_surface`, `lines_changed`, `new_files_count`) |
| qa | `ticket.md`, `implementation.md`, `plan.md`, `analysis.md` | `qa.md` (+ signals: `tests_added`, `tests_broken`, `coverage_change`) |
| review | `ticket.md`, `review-spec.md` (generated from brainstorm AC + chosen approach), `plan.md` (if any), `qa-facts.md` (generated from qa.md evidence), `analysis.md` | `review.md`, `review-spec.md`, `qa-facts.md` |
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

**Duplicate check.** `references/duplicate-check.md` is a shared, model-driven procedure. `n1-ticket` and `n1-story` run it before creation, `n1-start` runs it at intake, and `n1-queue` runs it at intake in annotate-only mode. It keyword-searches via `operations.search` (max 10 hits), classifies hits inline as duplicate/related/unrelated, warns, and offers links via `operations.linkIssues` (`Duplicate` / `Relates`). It is skipped silently when `search` is absent. The link offer is dropped when `linkIssues` is absent. In `n1-start` intake, every `duplicate` hit is auto-linked without prompting in every autonomy mode; `related` hits are also auto-linked whenever links are offered, in every autonomy mode, and never block with a prompt — when `linkIssues` isn't configured, related hits are left unlinked with a warning only. Results are cached per ticket in the overview.md frontmatter key `duplicate_check`. In n1-queue, intake only annotates (`CONTEXT=queue`); the preview resolves flagged candidates interactively (`CONTEXT=queue-plan`: continue, link, or exclude, recorded in the plan's `## Decisions` Notes), and queue children skip the check.

**Follow-up filing.** `references/followup-filing.md` is a shared, model-driven procedure (N1-102). With `qualityEscalations=auto-accept` (hands-off), the review fix, QA fix, n1-pr Codex step, and FINALIZE MEMORY append proposed follow-ups to `## Follow-ups` in overview.md instead of offering them. n1-start FINALIZE MEMORY then files them before Gate 3:
- runs the duplicate check (`CONTEXT=create`); a duplicate hit is linked, not recreated
- creates each ticket under the ticket-scope rule, at most 5 per ticket (resume-aware)
- marks each line in place: `[pending]` before create (resume reconciles by tracker search), `[<KEY> unlinked]` after create, `[<KEY>]` after the Relates link succeeds; this makes resume idempotent and retries failed links
- posts one tracker comment and adds a `Follow-ups:` line to Gate 3

Ask mode never appends or files. Tracker failures warn and never block.

When `tracker.assignToCreator` is not `false` (default ON), tickets are assigned to the currently-authenticated tracker user via the `getCurrentUser` + `assign` operations, at two points: creation time (`n1-ticket`/`n1-story`, writing `ticket.md`) and, for every ticket entering `n1-start` (including queue-picked or pre-existing tickets), the unassigned-ticket guard in `analysis.md` Step 2 — which never steals an existing assignee. Non-fatal on failure. When `getCurrentUser` or `assign` is absent (legacy configs), assignment is skipped and `n1_assign_gap_warn` (`lib/config.sh`) prints a one-line visible warning once per run (`n1-start` step 2, `n1-ticket` compose, `n1-story` collect) — skip logic and the existing-assignee guard are unchanged. A plain `n1-init` re-run backfills the missing operations through the Operation Gap Check (prompted; names inferred from `readTicket`, only empty keys written). Configured by `n1-init`.

Optional `tracker.operations.addToSprint` (Jira via jc-mcp: `jcm_addToActiveSprint`) is called once with the ticket key right after the initial In Progress move in `analysis.md` Step 2, routed via `versionMcp` else `mcp`. Unset → skipped silently. `ok:true` (added or `skipped`, e.g. Kanban) → one `## Progress` line; `ok:false` or tool error → one-line warning. Never prompts, non-fatal; the Blocked and resume moves do not call it. `n1-init` sets it when `mcp__<server>__jcm_addToActiveSprint` is exposed and backfills existing Jira configs through the Operation Gap Check (offered only when that tool is exposed).

On brain-dump/file runs where the user opts to create a ticket, `n1-start` adopts the **created ticket ID** as the per-ticket memory `<ID>` and worktree name. An ID-Final invariant blocks any memory/worktree write until that ID is known; if state was already written under the provisional slug, the idempotent `Reconcile Memory ID & Branch` procedure moves the memory folder (inside `$N1_HOME/memory/`) and renames the worktree directory to the ticket-ID-based names.

## Type Registry

Workflow types are declared in `pipeline.json` under `types`. Each type defines its step sequence, detection rules, and optional per-step model overrides.

| Type | Steps | Detection | Key differences |
|------|-------|-----------|-----------------|
| `task` (default) | ticket → analysis → [brainstorm] → [plan] → [plan-review] → implementation → qa → review ⇄ fix → [local-testing] → pr → [ci] → [finish] → [release] | `detect.default: true` | Full pipeline |
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
| analysis | `blast_radius`, `security_relevant`, `files_changed`, `complexity_delta`, `has_bug_root_cause`, `self_resolved`, `ticket_contradictions` | analysis.md |
| brainstorm | `planning_need`, `design_clarity`, `approach_count`, `files_changed`, `blast_radius` | brainstorm.md |
| implementation | `diff_surface`, `lines_changed`, `new_files_count` | implementation.md |
| qa | `tests_added`, `tests_broken`, `coverage_change` | qa.md |
| investigation-deliverable | `confidence`, `implementable`, `unknowns_resolved`, `findings_count`, `recommendations_count`, `self_resolved`, `validation_confidence` | investigation.md |

Helpers in `lib/signals.sh`: `n1_read_signal`, `n1_write_signals`, `n1_eval_signal_gate`.

## Model Tiering

`n1_resolve_model` accepts an optional context parameter for signal-driven model selection, while dispatchers use `n1_resolve_agent` to receive the coherent model/effort pair. Rules are host-neutral: resolution is override > escalation > downgrade > task type > baseline. Tier keywords remain `frontier` (opus), `standard` (agent default), `downgrade` (one tier below), and `minimal` (haiku). Triggers defined in `pipeline.json` under `escalation_triggers` and `downgrade_triggers` are condition-gated through `n1_eval_signal_gate`; when the same key appears in both sections, escalation is checked first. The `developer:implementation` step can promote to frontier when `analysis.blast_radius` is `high` or `analysis.security_relevant` is `true`.

Claude output is unchanged (`opus`/`sonnet`/`haiku`). The only permitted runtime differences are a declared escalation, downgrade, or task-type override. Telemetry repair and empirical validation are not part of this routing policy; NP-132 owns telemetry repair and empirical validation.

## Memory Compaction

Memory files are not compacted. N1-145 removed `n1_compact_memory` because its heading keep-list silently dropped `n1:unknown` tags and the Data Flow, Recommended Patterns and design Components that downstream personas read, while implementation.md compaction saved about 0%. Older runs may still have `<file>.full.md` copies on disk.

## Analysis Cache

Project-level snapshot that eliminates redundant codebase discovery on sequential tickets. Gated on `analysisCache.enabled` in `$N1_HOME/config.json` (default `true`).

**Snapshot location:** `$N1_HOME/cache/project-snapshot.md` — structured, schema-versioned document with provenance comments per section. Not a memory file — it's a cache artifact scoped to the project, not a ticket.

**Lifecycle:** First ticket (cold start) generates the snapshot as a byproduct of full analysis. Subsequent tickets (warm start) inject it into the solution-architect's prompt, skipping project-level discovery. Stale snapshots trigger full regeneration.

**Invalidation (full-snapshot, v1):** git-diff-based classification against `analysisCache.structuralFiles` (force stale), neutral-file threshold (fixed at 15), and TTL (fixed at 4h). Provenance comments stored per section for future partial invalidation.

**Fail-open:** Any cache failure (corrupt file, missing SHA, git error) falls back to full analysis. `SNAPSHOT_DRIFT` markers from the agent force regeneration on the next ticket.

**Helpers:** `lib/cache.sh` — `n1_snapshot_path`, `n1_snapshot_check_freshness`, `n1_snapshot_read_body`, `n1_snapshot_write`, `n1_parse_ttl`.

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `analysisCache.enabled` | boolean | `true` | Master gate |
| `analysisCache.structuralFiles` | string[] | See `defaults/analysis-cache.json` | Glob patterns for structural files |

## Cross-Repo Awareness

Optional feature for exploring related projects' code during analysis and investigation. Gated on `relatedProjects.enabled` in `$N1_HOME/config.json` (default `false`).

**Project Map:** `$N1_HOME/cache/project-map.md` — lightweight structural index (~300-500 tokens) of a project's navigable surface: modules, API surface, exports, integration points, key files. Generated by the solution-architect as a piggyback during analysis (same lifecycle as project-snapshot.md). Used by cross-repo consumers to navigate related codebases without blind exploration.

**Related Projects:** `relatedProjects.projects[]` in config — registry of cross-repo relationships. Each entry has `slug` (maps to `~/.n1/<slug>/`), `reason` (relevance hint), and `source` (`"auto"` or `"manual"`). Resolution: slug → peer config → `repoPath` + project map.

**Directionality (by design):** registration is one-directional. `n1_related_add` writes only the current project's config — adding B to A does **not** register A in B. This preserves the write-boundary discipline every N1 write path follows: a run never mutates another project's `$N1_HOME`. It also keeps the write atomic (a single `jq` + `.tmp` + `mv`), keeps removal single-sited, and stops an auto-detected false positive from polluting two configs. Bidirectional awareness is achieved by registering explicitly in both projects — the `assistant` ↔ `document-ingestion` pair is the reference example. Do not add backlink-on-write or union-at-resolve behaviour without revisiting this decision.

**Auto-discovery (during analysis):** The solution-architect emits `XREPO_SUGGEST: <slug> <reason>` lines for projects it discovers (incremental — skips already-confirmed projects). The orchestrator auto-adds via `n1_related_add` in hands-off mode, or — in interactive mode — persists the suggestions to `$N1_HOME/memory/<ID>/xrepo-pending.tsv` (skill Bash blocks are separate invocations, so shell variables cannot carry state across the prompt) and asks the user yes/no/select. Approved slugs are added via `n1_related_add` and recorded as `[asked]` Decision Ledger rows. No confidence tiering; no CLAUDE.md reading.

**Auto-discovery (during `n1-init`):** Three-tier confidence cascade — high (direct import/require in file contents, `.proto`/`.graphql` refs) → auto-add with `source:"auto"`; medium (yaml/yml/env references) → read the candidate's CLAUDE.md, present to the user for confirmation; user choosing "Add all" records entries with `source:"auto"`, explicit per-entry confirmation records `source:"manual"`; low → skip. Slug/service matching is literal (metacharacters escaped via `n1_related_escape_ere`) with non-alphanumeric boundaries, the same as runtime detection. **Bare registrations** — peer configs holding only `version` + `repoPath`, hand-authored so a repo is readable for cross-repo context without running N1 in it — stay candidates but are capped at medium confidence and always routed to the confirm prompt, since there is no tracker or CLAUDE.md context to corroborate an automatic match.

**Runtime detection:** Post-implementation diff scan (`n1_related_detect_in_diff`) detects unregistered cross-repo references; the current project is always excluded, and slug/service matching is literal (metacharacters escaped) with non-alphanumeric boundaries. Detections are persisted to `$N1_HOME/memory/<ID>/xrepo-runtime.tsv` so the prompt response (a later Bash invocation) can act on them. In hands-off mode, auto-adds to config. In interactive mode, presents suggestion. The review step injects the registered related projects list into the code-reviewer prompt, which flags unregistered cross-service calls as advisory `[XREPO-N]` findings (non-blocking).

**Pipeline touchpoints:**

| Step | Cross-repo behavior |
|------|-------------------|
| Analysis | Auto-discovery + exploration. SA reads project maps and code from related repos. |
| Investigation | Same as analysis — traces bugs across service boundaries. |
| Implementation | Post-impl diff scan for runtime detection. |
| Review | `[XREPO-N]` advisory findings for unregistered cross-service calls. |

**Freshness:** Local project map follows analysis cache lifecycle (regenerated on cold/stale). Cross-repo consumers treat maps older than 72h as stale (fixed, TTL-only — no git-diff for remote repos).

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `relatedProjects.enabled` | boolean | `false` | Master gate |
| `relatedProjects.projects[].slug` | string | — | Maps to `~/.n1/<slug>/` |
| `relatedProjects.projects[].reason` | string | — | Why related (relevance filter) |
| `relatedProjects.projects[].source` | string | — | `"auto"` or `"manual"` |

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

When `tier == simple` AND `blast_radius == low` AND `files_changed < 3`, the implementation step bypasses the n1-implement dispatch loop and spawns a single developer agent directly. Fallback to full n1-implement if the developer fails. Gate checked before the existing planning_need routing. Signals are read from `brainstorm.md` first (post-design, scope-aware); falls back to `analysis.md` when brainstorm was skipped.

## Lite-Analysis Gate

When `tier == simple` AND `description_quality` is `adequate` or `weak` AND `type` is `task` or `chore`, the analysis step runs the solution-architect with reduced scope. All three inputs exist before analysis runs: `tier` and `type` from `overview.md` frontmatter, `description_quality` from the `ticket.md` signal block. Note that `task` is the pipeline's catch-all type (`pipeline.json` → `types.task.detect.default`), so the gate is not limited to housekeeping work — small features and improvements resolve to `task` and are lite-eligible too; the escape hatch below is what keeps that safe.

The analysis step **produces** the signals downstream gates consume, so it can never be skipped. Lite mode changes how much work produces the signals, not the signals themselves — the architect's Output Contract (`n1:signals` line, `tier:` line, `context:` block) is identical in both modes.

**Stripped in lite mode:** industry-standards web research, cross-repo exploration (the `relatedProjects` block is skipped entirely, including peer-map freshness checks), observability enrichment, snapshot persistence, and project-map generation. The codebase scan narrows to the files the ticket touches, and the report is capped at 300 words.

**Not stripped:** the model. Every combination the gate accepts resolves to a downgraded (Sonnet) architect, so lite runs trade scope for capability nowhere. Three rules cover the four cells: the `solution-architect:analysis` downgrade trigger matches `adequate` descriptions on any non-investigation ticket, and matches `weak` descriptions on `simple` + `task`; `types.chore.step_overrides` covers `chore` regardless of quality. The `weak` clause is deliberately narrowed to `simple` + `task` — a weak description on a `standard` or `complex` ticket is exactly where the frontier architect earns its cost. Lite mode itself never changes the tier: codebase verification is the safety net, so the savings come from scope, not capability.

**Escape hatch:** if the architect finds the task touches 3+ files, spans modules, touches auth/crypto/secrets/input-validation, changes a public API, or changes a schema or contract, it abandons the lite budget, emits corrected signals, and returns `LITE_ESCALATED: <reason>`. The orchestrator logs it to `## Key Decisions` and continues — analysis is never re-run. The corrected signals then drive the existing `pipeline.json` escalation triggers.

**Cache interaction:** a lite run writes no snapshot, so a cold cache stays cold and the next standard-tier ticket warms it. A `fresh` snapshot is still consumed — that path already skips project discovery and composes with lite's other reductions.

**Telemetry:** the decision is recorded as `lite-analysis-gate` on both outcomes via `n1_record_decision`, so `/n1:n1-telemetry` can correlate lite runs against review pass rate, fix cycles, and `LITE_ESCALATED` frequency. A high escalation rate means the gate is too loose. No config key — the gate is purely signal-driven, like the Implementation Simplicity Gate.

## Ticket Description Enrichment

Optional two-phase enrichment that writes structured content back to the tracker when a ticket description is poor or absent. Gated on `ticketEnrichment.enabled` (default true) and the `editTicket` operation existing in config.

- **Phase 1** (product-analyst, Step 1): quality assessment (Empty / Skeletal / Weak / Adequate) → silent append for empty/skeletal descriptions, silent rewrite for weak descriptions. Idempotency markers: `*Structured by N1*` / `*Restructured by N1*` / `*Refined by N1*` (n1-refine; Scope/Decisions/Assumptions copied verbatim to ticket.md).
- **Phase 2** (orchestrator, after Step 3 Brainstorm): appends refined acceptance criteria and scope boundaries to description, posts a design summary comment. Idempotency marker: `*Refined after design review — N1*`.
- **Queue plan brief** (n1-queue Plan-Resolve 1, before any child runs): Empty/Skeletal candidates get a short brief (core ask + 2-4 acceptance criteria) marked `*Briefed by N1 (queue plan)*`. This is not an idempotency marker, so product-analyst still runs Phase 1 in full on briefed tickets.
- **Title & form repair** (product-analyst, before Phase 1. n1-queue Plan-Resolve 1 applies it by reference, before the Desc Checksum): a placeholder summary (`error`, `bug`, `todo`, ...) or a ≤2-word summary that an embedded `Title:` line beats is replaced via `editTicket`. A raw form dump (`Type:`/`Title:`/`Area:`/`Details:`) gets an appended Core Ask + acceptance criteria block marked `*Normalized by N1*`, which counts as already enriched. Queue children never write the title (desc hash chain).

Both phases are non-blocking — MCP failures are logged and skipped. Freshly created tickets (brain-dump/file/error-tracker modes) skip Phase 1 (adequate by construction).

In queue children (`N1_QUEUE_RUN_ID` set), every description write (Phase 1, Phase 2, investigation update) goes through `references/desc-hash-chain.md`. The resulting hash is recorded in `memory/<ID>/.desc-hashes` only when the pre-write text was already trusted, so the headless content guard keeps accepting N1's own edits.

## Ticket Watch

`lib/ticket-watch.sh` + `skills/n1-start/procedures/ticket-watch.md` / `ticket-watch-react.md` (N1-89). The orchestrator probes its own ticket before Steps 5, 6, 10 and 11b with one `jcm_searchIssues` call (`key = <ID>`, `maxResults: 1`). `n1_tw_cmp` compares the raw `updated` with the cursor `$N1_HOME/memory/<ID>/.ticket-watch` (seeded at the end of Step 2) and stays silent when nothing changed. On change, `jcm_getIssue` + `getChangelog` feed `n1_tw_delta`, which keeps only comments with an unseen `(id, updated)` and changelog items whose author is not `me` (cached `getCurrentUser`). It advances the cursor before anyone sees the delta, so own writes and repeated checks never loop. The digest caps (10 comments, 10 changelog items) leave the remainder pending (old `updated` kept, withheld comments not `seen`, `changelog_since` stops at the last delivered entry; digest `pending: true`). The stop status is the latest status item across all authors (external author and Done/Blocked target), or the current `getIssue` status when the last changelog page is truncated. A Done/Blocked status set by someone else pauses the run deterministically. Other deltas are judged inline: `info` is surfaced (headless: `ticket_comment` queue event + notify), `replan` restarts at Step 1 (max 2 per run, `ticket_replan` event + tracker comment), and `alwaysAskOn` categories escalate. Active only when `watch.enabled` (default true, `defaults/watch.json`) and `tracker.operations.getChangelog` is mapped (jc-mcp only; YouTrack unmapped).

## Local Testing

When `localTesting.enabled` is true, n1-start runs a local verification phase (Step 9) after Review and before PR. Behavior depends on `localTesting.mode` (configured by `n1-init`, or inferred by `n1_resolve_local_testing_mode`: `localTesting.autoLive: true` plus a root compose file -> `"live"`; startCommand present -> `"live"`; otherwise `"test"`):

- **`"live"`** (default when startCommand is configured): The local-test-planner discovers infrastructure, app startup (auto-detected or via `localTesting.startCommand` config override), and existing e2e test suites. Execution runs existing e2e tests first, then generates ad-hoc curl/CLI scenarios only for acceptance criteria not covered by the e2e suite. Enforces Runtime First mandate (NP-78).
- **`"test"`** (default when no startCommand): Runs existing test suites only with no infrastructure startup. The planner suppresses Runtime First and produces test-suite-only plans.
- **`"smoke"`** (cloud-native services): Skips the local-testing step entirely with `smoke_deferred` telemetry. An absent `finishWork.postDeployVerification.enabled` falls back to this explicit mode; an explicit `false` disables post-deploy verification.

Bounded fix loop (live/test modes): `localTesting.maxFixAttempts` (default 3). On by default; configured by `n1-init`.

`localTesting.autoLive` (bool, default `false`) — opt-in: when `true` and `mode` is unset, a root `compose.yaml`/`compose.yml`/`docker-compose.yaml`/`docker-compose.yml` resolves mode to `"live"`. An explicit `mode` always wins. Not a `pipeline.json` gate (it changes mode resolution, it does not skip a step). `n1-init` asks about it only when a compose file is detected.

The QA dedup gate (skip when every QA Runner command is pytest) applies in `"test"` mode only. `localTesting.teardownCommand`, when set, runs in the 9c cleanup step on every attempt, including failed ones.

**Enable offer:** when a root compose file exists but live testing would not run (`enabled: false` or resolved mode is not `"live"`), `hooks/session-start.sh` injects a `LOCAL TESTING OFFER` instruction: if the user asks for local/docker/e2e testing, the orchestrator performs that test, then offers once to enable live testing (writes `enabled: true`, `autoLive: true`; never touches `mode`). A decline is not re-offered in that conversation; when a ticket is active, the answer is logged as a Decision Ledger audit row. Nothing is injected when live testing is already on.

Local testing owns all live-app verification -- starting services, running e2e suites, hitting real endpoints. QA owns the unit test suite. These scopes are independently defined; neither is conditional on the other being enabled.

The PR body uses a unified `## Verification` section (not separate `## Test Plan` / `## Local Testing`). The tech-writer merges QA verification steps with local testing results via best-effort semantic matching -- matched items show checked/unchecked with evidence, unmatched items from either source are included as-is.

## Test Coverage Tiers

The n1-start QA step always passes the `maintain` test-coverage tier to qa-engineer (no config key). QA writes **unit tests only** — testing individual functions, modules, and handlers in isolation. Integration and e2e verification belongs to the local testing step. Three tiers:

| Tier | QA behavior |
|------|-------------|
| **maintain** (default) | Run existing unit tests, fix breakage, update for changed functionality. No new tests. |
| **minimal** | Maintain + 1–3 focused unit tests per feature, acceptance-criteria-only |
| **standard** | Minimal + edge cases + error paths, capped at 10 per test file / 3 per group. Unit-level only. |

Cross-tier invariants: broken tests are always fixed, tests for removed functionality are always updated. QA never writes tests that require starting the application or making HTTP requests to a running server.

The code-reviewer evaluates a **Test Quality (TQ)** dimension with `[TQ-N]` prefix findings (Medium/Low severity, non-blocking). A TQ fix loop (Step 7b in n1-start) spawns the QA agent to fix flagged tests before the review fix loop.

**QA evidence and verification gate.** Each QA run writes a `### Evidence` subsection to `qa.md` containing the exact runner command, exit code, and last ~10 lines of output from the Step 6 full-suite run. The orchestrator always re-executes the suite via Bash after the agent returns, stores the log under `$N1_HOME/memory/<ID>/qa-verify.log`, and records any exit-code mismatch in overview Key Decisions. If Evidence is absent or the fallback qa.md was written, the orchestrator sets `qa_verdict_unverified: true` in overview.md frontmatter, records a Key Decision ("QA degraded: unevidenced verdict"), and the review step instructs the code-reviewer to treat the QA pass as unconfirmed when evaluating Test Quality.

**Break-check.** After QA returns, the orchestrator verifies that tests can fail using `lib/breakcheck.sh`: non-test files are checked out from the branch point, the named test is run and must appear in the failing list (parsed by `lib/testparse.sh`), then `HEAD` is restored and the suite must be green again. Bug tickets: the `Regression test:` line in `qa.md` is mandatory and a `never-red` or `inconclusive` verdict fails QA and starts a fix cycle. Other types: each `New test:` line (up to `qa.breakCheckMaxTests`, default 5) is checked and hollow tests become non-blocking `[TQ-N]` findings for the code-reviewer. Modes via `qa.breakCheck`: `bugs` (default), `all` (blocking for every type), `off`. Verdict stored as `break_check_verdict` in overview.md frontmatter; logs under `$N1_HOME/memory/<ID>/break-check.log*`.

## Codex Review

`skills/n1-pr/steps/03-codex-review.md` calls `bash scripts/codex-pr-review.sh <PR_URL>` before triage and the final report; the triage text lives in `skills/n1-pr/procedures/codex-triage.md` and is read only when the review ran with triage on and reported findings. The runner defaults review on (`crossHostReview.enabled: false` opts out), bounds `codex login status` to 10 seconds (`N1_CODEX_AUTH_TIMEOUT`), and bounds the read-only Codex review to 900 seconds (`N1_CROSS_HOST_REVIEW_TIMEOUT`). It posts a `## Codex Review` comment or saves the findings beside the receipt if posting fails. When the review ran, triage is on by default (`crossHostReview.autoTriage: false` opts out): Critical, High and Medium findings (all findings when `qualityEscalations=auto-accept`, so N1 fixes instead of suggesting) are validated by a `code-reviewer` dispatch (no output path; its Write is hook-scoped to `memory/<ID>/review-(cr|sec).md`, so it writes no file) against the `gh pr diff` output and the checked-out PR head (`CONFIRMED`/`INVALID`/`UNVERIFIED` with file:line evidence; `UNVERIFIED` goes to human review); the developer fixes only confirmed findings and commits without pushing (one pass by default, `crossHostReview.maxFixAttempts`); the orchestrator pushes (via `scripts/codex-push-gate.sh`, fail closed) only if the PR is not a fork PR, `origin` is the PR head repository, `START` is an ancestor of `HEAD`, and every path touched by any outgoing commit is inside the PR's diff files (or is a new regular file in the same directory as one, never at the repo root, never a dot-file or under a dot-directory, never executable or a symlink, never a loader/manifest file (e.g. CLAUDE.md, AGENTS.md, compose files, package manifests, lockfiles, *.config.* and *rc.* tool configs, tsconfig/jsconfig, conftest.py), and only with the same extension as a listed file in that directory) and none is CI or credentials (the push is bounded by `N1_CODEX_PUSH_TIMEOUT`, default 90s, and never prompts), otherwise the findings go to human review and the gate saves the unpushed fix as a patch under `memory/<ID>/` (no patch when a CI or credentials path matched) and resets the branch to the run-start head (`reset=<sha>`; `kept=<sha>` when it cannot); the PR body is reconciled; and a `## Codex Review Triage` comment (posted with `gh pr comment --body-file`, never via shell text) lists auto-fixed, validator-dismissed, developer-dismissed and human-review findings. Low, unclassified, and any finding whose validation, fix or push failed go to human review. Triage never prompts or blocks, so unattended and headless runs behave the same; Codex output stays untrusted data throughout. The N1-116 soft-findings policy does not apply to Codex triage (N1-123): this loop already makes one fix pass with no re-review, and its fixes also pass the validator and the push gate; Low findings stay fix candidates under auto-accept (N1-94).

The PostToolUse PR observer independently records successful `gh pr create` output with `outcome=skipped reason=step-not-run`. The PR creation snippet also writes that fallback for hosts without the hook. A Stop hook requests continuation once for unprocessed PRs, before telemetry finalization; it does not run model work itself. Because the observer only sees a literal `gh pr create`, `n1_review_check_run` (lib/codex-review.sh) also looks up PRs on the active-run branch (open PRs via `gh pr list --head`, 10-second bound, fail open) and records the same fallback for any PR with no processed receipt in any session; the Stop hook, n1-start's PR-step post-condition and FINALIZE (before `n1_active_run_clear`) all call it. Runner outcomes replace the fallback with `ran|skipped|timeout|failed`. Session-scoped JSON receipts under `$N1_HOME/review-receipts/<session>/` survive without telemetry; available run telemetry also receives a `codex-review` decision with `pr_url`. The benchmark reports reviewed PRs divided by all known PRs, including missing decisions and incomplete runs with a known PR URL. Repeated decisions for one PR use the last outcome.

**Soft-fix disclosure (SEC-4, N1-123).** Soft-pass review fixes (N1-116) are never re-reviewed, so the Codex PR review is their only cross-review. Before the Triage Gate, step 3 posts one `## Soft-Pass Fixes Not Cross-Reviewed` PR comment (body written to a `mktemp` file, posted by PR URL with `gh pr comment --body-file`, so fork and cross-repo setups hit the right PR) when `codex_review_outcome` is not `ran` and `$N1_HOME/memory/<ID>/implementation.md` has a `## Fix Cycle <N> (soft)` heading. The human merger then knows those commits are not cross-reviewed. A failed post, a malformed PR URL (`softfix:bad-pr-url`) an unresolved ticket ID (`softfix:no-id`) or an existing but unreadable implementation.md (`softfix:unreadable`; a missing file is `softfix:none`) only warns inline and continues; none of them is reported as `softfix:none`. Re-runs skip posting when a comment with the notice heading already exists (`softfix:already-posted`); a failed lookup posts anyway. Accepted residual gap: the commits can still merge without review, and the full suite (and CI, if configured) and the human merge checkpoint remain the controls. With `prMode: skip` there is no PR and no Codex run, so no notice is posted (the user merges locally after running the pipeline). A failed post leaves only the inline warning.

## PR Body Reconcile

`references/reconcile-pr-body.md` keeps the PR description in sync with pushes made after PR creation (N1-79). n1-ci (Step 1 capture, Step 7a or before finish chaining in Step 4), the n1-pr Codex triage fix cycle, and n1-review-response Step 6a record the PR head SHA at run start in its own `mktemp`-generated `$N1_HOME/scratch/reconcile-start-<PR>.<rand>` file (keyed by PR number plus a random suffix so standalone runs without a ticket ID work and overlapping runs on the same PR don't collide), and carry that path forward to § Check the same way `<D>` is carried from `reconcile:run dir=`. Every fix-cycle exit that may follow a developer push — exhaustion, escalation/abort, and dispatch-failure branches in all three call sites — routes through this reconcile before any final report, not only the clean-pass path. At the end of the run, if the head moved, tech-writer runs once in `mode: reconcile`. It re-checks every claim against the PR diff, copies Deployment Actions checkbox lines and every locally-verified/manual-check annotated line verbatim, may reword (but never untick or drop) a plain `- [x]` line outside that frozen set when the diff makes its stated fact stale, passes unknown sections through, lists possibly stale docs under Review Notes instead of editing them (a doc commit would trigger another push), and runs deploy-action detection against the untruncated `full diff` file (grepped, not read whole) so a diff over the 30KB read cap can't hide a deploy action. § Apply refuses a revised body that drops or changes a frozen line, or that lowers the total count of ticked `- [x]` lines, re-fetches the live PR body just before posting and aborts if it changed since § Check (concurrent edit) or the re-fetch fails, strips a trailing stray `</content>` wrapper line if present, posts via `gh pr edit --body-file`, and never blocks the run. A metadata fetch failure in § Check still consumes the start file before reporting `reconcile:failed:fetch`. Ad-hoc pushes outside a skill follow the same procedure with `ADHOC=1` via the HOST ROUTING `PR BODY RECONCILE` line.

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

`n1-start` runs stop after PR + CI: the human merges, then runs `/n1:n1-finish`. With `autonomy.fullAuto` (N1-146) FINALIZE MEMORY ends (after Gate 3) by invoking n1-finish with `<ID> chained` when the run produced a PR (or `prMode: "skip"`) with green or absent CI (never after failed/escalated CI; n1-release is never chained); without `mergeOnFinish` the chained run stops on the open PR. The ticket is closed **only when the code is actually merged**, never on green-CI-but-open.

- **Merge** (`finishWork.mergeOnFinish`, default `false`; N1-140): only a JSON `true` turns it on (`n1_finish_merge_enabled`, `lib/config.sh`). Then interactive `/n1:n1-finish` merges an open PR: failing, cancelled or pending CI stops it (no CI is fine), unresolved review threads need the user's OK, before-deploy actions run first, then, only when the PR head equals the reviewed-head pin (`n1_review_pin`, `$N1_HOME/review-pins/<owner>_<repo>_<pr>`; set by n1-pr Step 9, set only when the PR head equals the local branch tip N1 pushed, advanced by reconcile § Check only to a new head that is that local tip and when the run started at the pinned head; N1-141), `gh pr merge --<mergeMethod> --match-head-commit <pin>` with no auto-merge, no remote-branch deletion and no retry (except the single resolve-then-retry below). A different head never falls back to the current head: an interactive run offers `skills/n1-finish/references/repin.md` once per run (re-review the checked-out PR branch with `/n1:n1-review --full`, lease-push its fix commits, `n1_review_pin set` only after `Verdict: PASS`, CI wait, then the 3.1 checks rerun; N1-142); declining, queue and headless runs stop with a message. A pin lookup failure (`pin:unavailable`) always stops. A missing pin (PR opened before N1-141) is pinned at the current head only after the user confirms in an interactive run, and only when the local branch tip equals the remote head (resolve-dirty.md § Re-pin); queue/headless runs escalate and stop (N1-151). The entry prints `merge-on-finish:yes` only when `n1_merge_authorized` (`lib/config.sh`) holds: `mergeOnFinish` true, and in queue/headless runs `autonomy.fullAuto` true as well; otherwise queue children stop at `queue-run:yes`. The merge-deny hook (`hooks/enforce-agent-policy.sh`/`.py`) denies `gh pr merge`, merge APIs and default-branch pushes in every session unless the same predicate holds (heuristic, not a bypass guarantee; `!`-prefixed user commands are not tool calls and are not seen). Without Python, queue children fail closed and other sessions fail open with a warning. A chained run with `prMode: "skip"` merges locally only with `merge-on-finish:yes`; a manual run keeps the local merge. Without the key, an open PR gets the before-deploy actions, then "merge, then re-run". A DIRTY (conflicting) or BEHIND PR is not a STOP when merge-on-finish is on: the first `state:DIRTY` or `state:BEHIND` in a run follows `skills/n1-finish/references/resolve-dirty.md` (rebase onto base, mechanical version re-bump for N1's manifests, other conflicts to the developer persona, lease push, pin advance, CI wait, then the 3.1 checks rerun; N1-144), in queue/headless runs too when `n1_merge_authorized` holds (N1-151; each failure there is an escalation plus a `N1 [headless]` tracker comment). The same route runs once after a failed merge whose re-read state is DIRTY or BEHIND (GitHub computes the state lazily, so 3.1 can read a stale CLEAN; N1-157), then the merge is retried once. A second DIRTY/BEHIND in the same run stops. Runs without merge-on-finish still STOP on DIRTY and BEHIND. `git.prMode: "skip"` merges locally (Step 2b).
- **Deploy watch** (always on): a pre-check skips the watch (`skipped (no deploy workflow)`) when `.github/workflows` is missing or no workflow has a `push`/`workflow_run` trigger; uncertain cases and a set `finishWork.deployWatch.workflowName` still watch. The watch follows workflow runs of every event on the merge commit with `n1_wait_release_runs <sha> 5 <minutes> '<workflowName>' any` (`lib/poll.sh`, 8-minute blocking chunks, no per-poll turns), optionally filtered by `workflowName`. Deploy failure leaves the ticket open.
- **Post-deploy verification** (`postDeployVerification.enabled`, default `false`): after a successful deploy only, the verifier receives absolute paths for ticket, analysis, optional local-test plan, PR diff, config, and local `dev-access.md`, then writes `memory/<ID>/post-deploy-verification.md` with one `PASS`, `FAIL`, or `SKIPPED` result per acceptance criterion. An absent key falls back only to explicit `localTesting.mode: "smoke"`; explicit `false` wins. Verification failures are informational and do not prevent closure.
- **Ticket close:** always attempted; requires `tracker.statuses.done` in config (detected by `n1-init`, or added manually); absent → finish skips closing with an explanatory message.
- **Delivery deploy** (`delivery.mode: "ssh"`, `delivery.command` or an ordered `delivery.steps` list (NP-240: shell/`Manual:` items per `references/deployment-actions.md`, each confirmed before it runs, `command` wins when both are set, abort resumes at overview `deploy_next_step`), optional `delivery.verifyCommand`; absent means off; NP-219): `skills/n1-finish/steps/03b-ssh-deploy.md`, entered at the top of Step 4 after the merge (PR or local). `n1_delivery_action` (`lib/config.sh`) prints `none`/`runbook`/`execute`.
  - Interactive runs: N1 asks the user, runs the command and the verify command (checks the exit code) from a temporary detached `git worktree` of the merge SHA (removed afterwards, so the feature checkout is never shipped), and closes the ticket on success. A decline or failure leaves the ticket open with a tracker comment.
  - Headless runs never execute the deploy. `n1_delivery_runbook` writes `memory/<ID>/runbook.md` (local only — never posted to the tracker, since it contains the literal `delivery.command`/`delivery.verifyCommand`) and sets overview `deploy_pending: true` (plus `deploy_merge_sha` once merged); the ticket gets only a short "deploy pending, resume with n1-finish" comment. Queue children never enter n1-finish (they stop after PR + CI), so nothing is deployed from a queue run; the ticket keeps its ordinary `pr` outcome.
  - `n1-finish <ID>` resumes the deploy, and skips the merge when `deploy_merge_sha` is set.
  - Independent of `git.prMode` and the deploy watch.
- **Deployment actions** (NP-226): `references/deployment-actions.md`. tech-writer writes a PR-body `## Deployment Actions` checklist (`### Before deploy` / `### After deploy`) from ticket.md's `### Deployment Actions` plus a diff scan. n1-finish runs before-deploy items in Step 2 before the merge, and after-deploy items at Step 4 after the delivery gate once the deploy is confirmed. n1-release collects unticked items from PRs in `PREV_TAG..<release target>` (`${MERGE_SHA:-HEAD}`, matching the SHA the tag is created at) plus the pending batch, flags conflicts at the Step 3 gate, runs before-deploy items before the tag push, and runs after-deploy items after Step 8. Executed items are ticked `[x]`, so re-runs skip them. Headless runs never execute an item: they write `runbook.md`, set `deploy_pending`, and do not merge.
  - **No deny hook covers `ssh`/`scp`/`rsync` in queue children.** The guard is the step's branch, not a PreToolUse hook. This risk is accepted, and n1-init tells the user when delivery is enabled.

## Release

Optional final pipeline step (`release`) that runs after finish, gated on `release.enabled` (default `false`) in `$N1_HOME/config.json`. The standalone `/n1:n1-release` skill works regardless of the gate.

Two modes: built-in gh flow (`procedure: null`) creates an annotated git tag and GitHub Release via `gh release create --generate-notes`; custom flow (`procedure: "<markdown>"`) walks the user through a pasted markdown procedure with placeholder substitution (`{{RELEASE_TAG}}`, `{{VERSION}}`, `{{MERGE_SHA}}`, `{{TICKET_ID}}`). The confirmation gate states whether a GitHub Release will be created. After a completed custom walk, a post-procedure Release check runs `gh release view`. If no Release exists, it offers `gh release create --generate-notes --verify-tag`, except when the tag is not on origin or when a workflow under `.github/workflows` that creates Releases is still running on the tag commit.

After the release, the deploy watch (always on, 30-minute budget, unfiltered) calls `n1_wait_release_runs` in `lib/poll.sh`. The helper polls only `release`-event runs on the tag commit, in foreground 8-minute chunks, and treats `gh` errors as "no information", never as a failure. The final report runs after the watch and states the outcome in a `Deployment:` line: succeeded, FAILED, timed out, could not verify, not triggered or not configured. A release whose triggered runs were all skipped reports "not triggered (all runs skipped)". Both flows end step 2 with an explicit hand-off, so the run cannot stop at the release URL.

Idempotent: `gh release view` check before creating; existing tag/release causes a skip. Tracker comment ("Released as vX.Y.Z") posted best-effort when a ticket can be inferred from the branch name.

Config keys: `release.enabled` (boolean, default `false`), `release.procedure` (string|null, default `null`), `release.draft` (boolean, default `false`). Tags are always `v<version>`.

## Agent Personas

11 atomic agents (plus the shared `research-standards.md` rubric) with scoped tools and configurable models:

| Agent | Default Model | Effort | Tools | Pipeline Stage |
|-------|---------------|--------|-------|----------------|
| product-analyst | sonnet | low | inherits (needs dynamic tracker + error-tracking MCP) | Ticket read, Error intake, Description enrichment |
| solution-architect | opus | medium | Read, Grep, Glob, Bash, WebSearch, WebFetch | Analysis, Bug investigation, Plan review (CCR) |
| planner | opus | medium | Read, Grep, Glob, Write, Edit, Skill, WebSearch, WebFetch | Plan writing |
| implementer | sonnet | medium | inherits (needs Skill for n1-implement, Agent for developer subagents) | Implementation (wraps n1-implement) |
| developer | sonnet | medium | Read, Edit, Write, Bash, Grep, Glob | Fix cycle, CI fix |
| code-reviewer | opus | medium | Read, Grep, Glob, Write (hook-scoped to the findings file) | Review (parallel) |
| security-reviewer | opus | medium | Read, Grep, Glob, Write (hook-scoped to the findings file) | Review (parallel) |
| qa-engineer | sonnet | medium | Read, Edit, Write, Bash, Grep, Glob | QA (tier-aware: maintain/minimal/standard) |
| local-test-planner | sonnet | medium | Read, Grep, Glob, Bash | Local testing (plan creation) |
| tech-writer | sonnet | medium | Read, Grep, Edit, Write, Glob | Doc update, PR content |

Models default to agent frontmatter values, overridable via `models` section in `$N1_HOME/config.json`.

Agent effort levels are static per-agent, set via subagent frontmatter `effort:` field (low or medium). Session-level effort (`/effort`, `effortLevel` setting) controls the orchestrator's reasoning depth — it does not propagate to subagents. There is no per-spawn effort parameter.

**Cold review.** The code-reviewer never receives `implementation.md` or `brainstorm.md`; it reads a generated `review-spec.md` (acceptance criteria and chosen approach) and derives the change surface from the diff. The orchestrator snapshots the working tree before spawning reviewers (`lib/treestate.sh`) and discards the pass if the tree moved. Every acceptance criterion gets a row in the reviewer's `### AC Coverage` table; a missing criterion is a High finding, and the tech-writer copies the table into the PR body.

Note: Sonnet 4.6 supports effort levels low, medium, high, and max (no xhigh).

**Trusted web research (always on).** `solution-architect` and `planner` carry `WebSearch, WebFetch` to research industry standards, best practices, and practitioner experience during analysis, planning, and plan-review. Research is constrained by the shared rubric in `agents/research-standards.md`: trusted source tiers, a marketing reject-list, ≥2-source corroboration, mandatory URL citation, a standards-over-soft-practices fitness gate (guards against over-engineering), and graceful degradation when the network is unavailable. Library API docs still go through Context7, not web search.
- **Single-pass analysis & research (v2.11.0):** the pre-plan `solution-architect` "deeper analysis" re-spawn was removed — the Step-2 `analysis.md` plus the `planner`'s native file discovery feed planning, and plan-review (4b) is the assumption safety net. Web research runs once (Step 2); 4b validates against the standards already recorded in `analysis.md` rather than re-researching.

## Host Layer

Claude Code is the only host. Skill text still uses host-neutral verbs ("dispatch persona", "ask the user", "invoke skill", `<N1_ROOT>`); `hooks/session-start.sh` injects a fixed HOST ROUTING block mapping them to Claude Code tools. `lib/host.sh` provides the plugin root, the session id, `n1_headless_cmd` (`claude -p`), and `n1_bg_*` (`claude --bg`).

## Session Start Hook

`hooks/session-start.sh` fires on session start/resume/clear/compact (payload field `source`). It resolves `N1_HOME` via `n1_home()` from `lib/config.sh` (env var → auto-derive from repo name → legacy git config → in-repo `.n1/`), then reads `$N1_HOME/config.json` and injects context telling Claude to prefer N1 skills. When a tracker is configured, it also injects a **TRACKER ROUTING** directive containing the tracker type, MCP server name, full operations map, and a negative instruction to never use any other MCP server. This keeps the correct MCP server name in the model's attention window throughout the session. After running `n1-init`, the user must `/clear` or restart to pick up the new config. It also records per-session facts to `~/.n1/sessions/<sid>.{json,preamble.sh}` (pruned after 7 days) and discovery facts to `~/.n1/host.json`, and injects `N1 PLUGIN ROOT` and HOST ROUTING.

## Question Notifier Hook

`hooks/notify-question.sh` is a PreToolUse hook on `AskUserQuestion`. When an interactive run blocks on a question it calls `n1_desktop_notify "N1 <ID>" "Waiting for your answer after <step>"` (`<step>` is the last completed step from `overview.md`; omitted when empty), backgrounded so the question is never delayed. It stays silent for headless or queue children (`N1_HEADLESS=1`, `N1_QUEUE_RUN_ID`), when this session has no keyed active-run pointer (questions outside an N1 run), and when `notify.onQuestion` is `false` (default on; only `false` disables). It is advisory and fail-open: every path exits 0 with no output. On WSL, `n1_desktop_notify` finds `powershell.exe` on PATH or at its default `/mnt/c` location (`n1_powershell_path`), so hosts with `appendWindowsPath=false` still get the toast.

## Escalation Model

Fixed checkpoints: after PR creation (Tech Lead reviews). Plan checkpoint is off by default (`requirePlanApproval: false`) — the plan-review CCR step validates the plan automatically. Enable `requirePlanApproval: true` to restore the manual plan checkpoint.
Confidence-based: low confidence + high blast radius = stop and ask.
Always escalate: security, architecture, public API changes.

## Autonomy

### `autonomy` block

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `mode` | `hands-off` \| `interactive` | `hands-off` (unset) | Single key controlling all autonomy behavior. `hands-off`: all mechanical prompts auto-resolve, brainstorm runs autonomously, acceptance gate auto-confirms. `interactive`: pipeline asks at every decision point. |
| `fullAuto` | JSON boolean | `false` | N1-146. `true` chains n1-finish after PR + CI. Merging still needs `finishWork.mergeOnFinish: true`; queue/headless runs merge only when both are true; those merges include N1's own post-review CI-fix and Codex-triage fix commits (the reviewed-head pin advances over them and no reviewer re-checks them; accepted, N1-146 SEC-3). N1-151 extends this to unattended DIRTY/BEHIND resolution: developer-resolved conflicts advance the pin after project tests and CI with no reviewer re-run (deliberately reverses N1-146 SEC-1); unattended pinless PRs escalate and are never auto-pinned (SEC-5 intact). Strings, numbers and invalid JSON count as `false` (`n1_fullauto_enabled`). |

Legacy keys (`brainstorm`, `mechanicalPrompts`, `qualityEscalations`, `acceptanceGate`, `escalationMargin`) are still accepted as a backward-compat fallback when `mode` is absent. A deprecation note is emitted at session start.

**Unconditional gates** (never affected by `autonomy.mode`): security/architecture/public-API escalations, release confirmation, prod deploys, secrets. The stop list is fixed in `n1_escalation_val alwaysAskOn` (`lib/config.sh`): security, architecture, public-api.

Every autonomous decision appends a row to the `## Decision Ledger` table in overview.md (spec: `skills/n1-start/ledger.md`); the ledger uses a 9-column format (step, category, tier, tag, question, chosen, alternatives, reason, rungs_tried — the 9th column added in v2.90.0). The tech-writer renders it as a `## Decisions` section in the PR body — the after-the-fact review artifact. Hard invariants: security/architecture/public-API escalations always block; **release is never automatic** — release is declared `manual_only` in `pipeline.json`, and the n1-release confirmation gate is unconditional.

Cross-session resume: the pr step writes a `## Pending` block (`awaiting: merge`) to overview.md; `hooks/session-start.sh` scans these (capped at 5 `gh pr view` calls, 30-min throttle via `last_checked`, 14-day expiry, fail-open) and suggests `/n1:n1-finish` when the PR was merged externally.

## Queue Orchestration

`/n1:n1-queue` runs tickets through `n1-start` sequentially via the background bash runner. Two modes: `--tag <tag>` searches the tracker for tickets tagged for batch work; `--story <ID>` runs the subtasks of a story. Also reached when `/n1:n1-start` is given an Epic, a Story with children, or a non-Story parent with subtasks (handoff to `n1:n1-queue --story <ID>`). A childless Jira Story is converted to a Task at intake (`n1_story_convert_decision`, N1-119) and runs as a single ticket; on YouTrack, without `tracker.versionMcp`, or when conversion fails, it runs unconverted, and overview.md records `story_convert`. A failed child search keeps the Story. A `--story` run on a Story with zero subtasks prints "no subtasks — run /n1:n1-start <ID>" and stops. The skill plans and `scripts/n1-queue-run.sh` executes. Planning (NP-203) is intake, preview, and Plan-Resolve: interactive duplicate resolution (`references/duplicate-check.md` `CONTEXT=queue-plan`), overlap ordering (`n1_queue_overlap_order` over per-ticket Touches derived from ticket text and the cached project map; overlapping tickets run lowest ticket number first), and a stop-list pre-scan that records a per-ticket pre-decision (`ask-at-runtime`, `pre-authorize`, `narrow`, or exclusion) for `alwaysAskOn` stop-list categories. Intake grades each description with product-analyst's tiers and never excludes on length. Only an empty description with a vague title (`n1_title_vague`: ≤3 words after a leading ticket key) is excluded, with reason `no usable content: empty description, vague title`. Plan-Resolve writes a brief marked `*Briefed by N1 (queue plan)*` to Empty/Skeletal candidates, shows it before Start, and takes the Desc Checksum from a re-fetch after the brief. A `--run` re-plan of a changed ticket repeats that step. The plan persists to `queue.md` with `step: planned`, `planned_at`, and a `## Decisions` table (`Ticket | Touches | Order | Stop-List Pre-Decision | Desc Checksum | Notes`, between `## Excluded` and `## Decision Ledger`). Bare `/n1:n1-queue` plans then launches after one Start prompt; `--plan` saves and stops; `--run <queue-id>` launches a saved plan, first re-validating it when `planned_at` is older than `queue.staleAfterHours` (default 24): pending rows are re-read, a changed status marks the row `skip`, and blocker check, duplicate resolution (`CONTEXT=queue-plan`), and Touches extraction re-run unconditionally for every pending row regardless of description-content-hash state; a changed description checksum additionally re-plans that ticket (re-brief, quality regrade), and the delta is confirmed before launch. `--dry-run` prints and persists nothing. The queue never creates a candidate's `memory/<ID>/overview.md` (that would trigger resume in the child).

Env contract: `N1_AUTONOMY_PRESET=autonomous` makes `n1_autonomy_val` return the fully autonomous profile. `N1_HEADLESS=1` auto-resolves ordinary prompts by taking the recommended option; prompts on the stop list become a recorded escalation and end the child. Escalation moves the ticket to `tracker.statuses.blocked` (when configured) and posts an idempotent `N1 [headless]` comment. Background children additionally get `N1_UNATTENDED=ask`: instead of ending the run, an escalation asks the user in-process and blocks (surfacing as `awaiting-human` via the existing bg-state polling); on answer the ticket moves back to `tracker.statuses.inProgress` and the run continues, or the run ends the same way as the non-ask path if the user chooses to stop the ticket. Every child also gets `N1_QUEUE_DIR` (absolute queue dir from the runner, tag and story mode alike). The headless guard reads the child's `## Decisions` row via `n1_queue_decisions_row` before escalating a stop-list prompt and applies a matching `pre-authorize`/`narrow` pre-decision without pausing, logged `[plan]`; the release confirmation gate never consults it. Its content check (TOCTOU guard) accepts any trusted hash (`n1_desc_hash_is_trusted`): the plan-time Desc Checksum, or a hash the child recorded in `memory/<ID>/.desc-hashes` after one of N1's own description writes (`n1_desc_hash_record`, scoped to `N1_QUEUE_RUN_ID`, recorded only when the pre-write hash was already trusted). A human edit after planning therefore still reads as `MISMATCH`, and a missing or unreadable `.desc-hashes` falls back to the plan hash alone. Children skip the duplicate check (`N1_QUEUE_RUN_ID` gate, recorded as `duplicate_check: queue-plan`). `N1_STORY_ID` is recorded in the child's overview frontmatter. `N1_STORY_PLUGIN_DIR` (optional) passes `--plugin-dir` to each Claude Code child.

The orchestrating session runs on the model the user invoked `/n1:n1-queue` with (the skill pins none). Model per ticket: sonnet by default; opus when size >= `queue.opusFromSize` (default M) or a risk flag is set. Outcomes: `pr`, `escalated`, `failed`. Helpers: `lib/queue.sh`; defaults: `defaults/queue.json`. Release remains manual.

### Queue Runner

`scripts/n1-queue-run.sh <queue.md>` is a pure-bash sequential batch executor. The queue.md file has YAML frontmatter (`run_id`, `pid`, `step`, `queue_id`, `planned_at`; `step` is `planned` for a saved plan, then `run`, `done`, or `halted`) and a `## Plan` table with columns `# | Ticket | Title | Repo | N1 Home | Model | Status | Reason`. Statuses: `pending`, `held` (N1-64: Reason `blocked_on <ID>`; released to `pending` by `n1_queue_held_sweep` once the user merges the blocker's PR, N1-114), `in-progress`, `awaiting-human`, `pr` (requires a recorded `pr_url` when the child's step is `pr`, N1-53), `escalated`, `failed`, `deferred`, `skip`, `done-before-run`. A child that finishes `pr`/`escalated` queues into a DRAIN list instead of stopping immediately (N1-74): its bg session may still be mid-CI-watch/finish/finalize after the terminal step, so it's only stopped once `n1_queue_bg_state` reports it `done` — checked every poll, plus once more at end-of-run and on halt (both before `strip_pid`), bounded by `subtaskTimeoutMinutes` and by `BG_POLL_GRACE` consecutive unreadable session-list reads (N1-76: a draining child that blocks on a question is escalated once via `n1_notify`, not silently logged as "left running"; the dedupe re-arms if the session returns to `working`, so a second question after an answer escalates again). Each child runs under `N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous` with `N1_QUEUE_RUN_ID` set to the run identifier. Children never merge unless `autonomy.fullAuto` and `finishWork.mergeOnFinish` are both true (N1-146); otherwise each ticket stops after PR + CI (N1-114). Defer-once: a first failure marks the row `deferred` and appends a new `pending` row with reason `deferred-retry`; a second failure stays `failed`. Three-strikes: 3 consecutive non-success outcomes (`failed`/`escalated`) halt the queue (`step: halted`, exit 2); a `pr` outcome resets the counter. Busy guard: exits 3 if frontmatter `pid` is alive. Helpers: `lib/queue.sh`; defaults: `defaults/queue.json`. The `--status` report writes `<queue-dir>/telemetry.json` with three counts derived by `n1_queue_decision_counts`: `plan_decisions` (Decision Ledger `preview|edit` rows), `autonomous_decisions` (sum of `headless` ledger rows across all non-pending/skip/done-before-run ticket overviews), and `escalations` (Plan rows with status `escalated`). On handoff (PR, escalation, failed) the queue tag is released via `skills/n1-queue/procedures/release-tag.md` (best-effort, `editTicket`); the runner stamps `queue_run_id` into the ticket's `overview.md`, and intake excludes a tagged ticket until `queue_tag_removed: true` confirms the release, so a stale tag never re-picks a ticket while a human re-tag re-queues it.

Host backend: each child runs as a `claude --bg` background session (`n1_bg_launch_cmd`, name `n1-<queue>-<ticket>-<row>`, N1 env passed via `--settings`), and the runner polls the session list every `pollSeconds` (default 30). The `-<row>` suffix (the Plan row number, not just the ticket ID) keeps session names unique across a defer-once retry: a retried ticket reuses the same ticket ID under a new Plan row, so its session name must differ from the row that failed. The runner still launches the next pending ticket only when no launched child is `working`. A child that blocks on a question becomes `awaiting-human` (no strike) and the runner moves on. Once the user answers, it counts as the working child again. Working time is capped by `subtaskTimeoutMinutes`: before stopping, `timeout_stop` (N1-77) re-reads the child's status to close a TOCTOU window — a child that reached a terminal step (e.g. `pr`) in the gap is drained and finalized with that outcome instead of being killed; otherwise the session is stopped and the row fails through defer-once. Once nothing is pending, parked rows are polled for up to `subtaskTimeoutMinutes` after the last park. Rows still waiting then stay `awaiting-human` with their sessions alive and the queue ends `done`. The Runs table has a `Session` column, and `--status` prints resume commands for awaiting rows (`n1_queue_awaiting_hints`). A launch refused because the bypass-permissions disclaimer was never accepted halts the queue with reason `bypass-permissions-disclaimer`. Background runs record no cost/turn metrics.

Observability: the runner appends one JSON line per transition to `<queue-dir>/events.jsonl` (next to `queue.md` and `runner.log`; append-only across runs). Every line has the same keys: `ts`, `queue`, `run_id`, `event`, `ticket`, `outcome`, `pr`, `session`, `duration_s`, `reason`. The events are:
- `queue_started`
- `ticket_started` (with `session` for background children)
- `escalated` (`reason` = first `## Escalations` entry, or a background session parking as `awaiting-human`; N1-60: when the child mirrored a question to `.question-<ticket>.json`, `escalate()` packs that file's full content — question/options/recommended/rationale, each capped at 2000 chars, options capped at 10 — into `reason` as JSON via `jq -c`, so the question survives the file's later removal. Control/format chars are stripped before capping (same class `n1_queue_watch` strips at render time) so single-byte control chars can't 6x-expand via `\uXXXX` JSON escaping; if the capped-at-2000 pass still exceeds a 32 KiB budget (e.g. fields full of 4-byte UTF-8 emoji), it's rebuilt at a 200-char per-field cap, keeping the packed reason far under execve's 128 KiB per-arg limit. `n1_queue_watch` detects this shape (`fromjson? | objects | has("question")`) and renders it the same way as the live file, falling back to the file when it's still present; the historical-replay path exempts a detected packed-question `reason` from the generic 300-char field cap applied to other fields)
- `unblocked`
- `ticket_finished` (`outcome` pr/failed/escalated/deferred; `duration_s` is runner wall-clock, never the child's `duration_ms`)
- `halted`
- `queue_done` (`reason` = `N PR / N awaiting / N failed`)

`--status` (`n1_queue_status_table` in `lib/queue.sh`) merges `queue.md`, `events.jsonl`, and `claude agents --json --all` into one table: `Ticket`, `State`, `Step`, `Elapsed`, `Cost`, `PR`, `Attach`. `State` is the Plan Status column, live-overridden for `in-progress`/`awaiting-human` rows from the matching background session's `n1_queue_bg_state` (same `missing`/`failed` degradation the runner already relies on; no second failure path). `Step` (per-ticket pipeline step, e.g. `review`) comes from the ticket's own `overview.md` frontmatter for in-flight rows and for `escalated`/`failed`/`deferred` rows (where the ticket stopped), and is blank for `pr` rows. `Elapsed` uses the already-computed `duration_s` from the row's `ticket_finished` event for terminal rows, or `now - Runs.Started` for in-flight rows. `Cost` is always `—`: no cost/turn metrics exist anywhere in the repo for background or headless queue children (a future ticket could parse per-turn cost if that gap needs closing). `Attach` is the `claude attach <session>` command for `awaiting-human` rows on Claude Code, blank everywhere else. `skills/n1-queue/steps/report.md` prints this table verbatim (no LLM reformatting) after the existing Plan table.

**Watching a running queue:** the launch confirmation and busy-guard messages point at `claude agents` (live per-ticket state, answer-in-place) in addition to `--status`.

**Opt-in statusline (`scripts/n1-queue-statusline.sh`):** a standalone script, not wired into any skill, meant to be added manually to Claude Code's `statusLine` command in `settings.json`. It deliberately does not source `lib/config.sh`/`lib/queue.sh` — sourcing the shared preamble alone measured well over the script's <50ms render budget — and instead re-derives the `N1_HOME` slug and re-reads frontmatter with inline `awk`/`jq` (kept in sync by hand with `n1_home()`/`n1_read_frontmatter()` if either changes shape). It reads the statusline's stdin JSON for `cwd`, finds the most-recently-modified `queue.md` under `$N1_HOME/queue/`, and prints nothing when there is none or its `step` isn't `plan`/`run` (a `done`/`halted` queue is terminal and would otherwise show forever as a stale line; a saved `planned` queue has not started and stays hidden too). Otherwise it prints one line: `<queue-id> <done>/<total> · <N> needs you · <ticket> <step> · <elapsed> · —` (the `needs you` and current-ticket segments are omitted when their count is zero, or there is no in-progress/awaiting-human row). The script never writes to `settings.json` and never overrides an existing statusline command — adding it is the user's own copy-paste choice. Example snippet for `settings.json` (only if no `statusLine` is already configured, or chained after the existing one):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash <plugin-root>/scripts/n1-queue-statusline.sh"
  }
}
```

`n1_notify <needs-you|done|info> <text>` (`lib/queue.sh`) sends best-effort alerts through `queue.notify`:
- `desktop` (default; `n1_desktop_notify` in `lib/host.sh` tries notify-send, osascript, then a WSL/Windows PowerShell toast, and logs a skip line to `runner.log` when none runs)
- `ntfy` (`queue.ntfyTopic`, a topic name or full URL)
- `command` (`queue.notifyCommand` receives `{"ts","kind","text"}` on stdin)
- `none`

Notifications fire on escalations (needs-you, with a resume hint when a session id exists — `n1-start <ticket>` once the session is draining/stopped on the success-path finalize, `claude attach <sid>` while it's still running), final failures (info), halts (needs-you), and once at queue end (done, carrying the digest). Individual PRs never notify. Notifier and event failures never affect the runner. On session start, `hooks/session-start.sh` adds one `N1 QUEUE STATUS:` line from `n1_queue_digest`, which folds local `events.jsonl` files (latest run per queue, latest event per ticket). It picks the queue active in the last 24h, preferring one with a ticket that needs you. Child per-step events are not emitted yet (deferred with NP-195).

**Session watch (NP-205):** `run.md` stamps `run_id` and `owner_session` (`n1_session_id`) into `queue.md` before launching the runner, then starts `n1_queue_watch <queue_dir> <run_id> <pid> 0` as a background watch in the launching session. Every `queue.pollSeconds` it relays new `escalated`, `answer_delivered`, `ticket_finished`, `halted`, and `queue_done` lines of that `run_id` only (a relaunch appends to the same `events.jsonl` under a new `run_id`). When an ask-mode child writes `<queue_dir>/.question-<ticket>.json` (question, options, recommendation, rationale) before escalating, the watch prints that full question instead of the truncated one-liner, alongside the `claude attach <sid>` fallback. `/n1:n1-queue --answer <ticket> <text>` relays a reply to the waiting child (`n1_queue_answer` in `lib/queue.sh`: stop the session, resume it by full session id with no flags, prompt prefixed `[n1-queue answer] `) and emits an `answer_delivered` event; a `.relay-<ticket>` marker (2-minute TTL) tells the runner not to finalize the stop as a failure. It saves its consumed-line count in `<queue_dir>/.watch-<run_id>.<session>`, so re-arming the identical command after a host timeout has no gap and no replay. It exits, removing the cursor, on halted, queue_done, or a vanished runner pid (relayed as `runner ... is gone`). `/n1:n1-queue --watch [<id>]` prints the status table and adopts a watch from the end of the file in any session.

**Held rows (N1-64, N1-114):** intake keeps a candidate whose only not-done blocker is in the same plan as `held` (Reason `blocked_on <ID>`) instead of excluding it. The runner never launches a held row directly. On every idle tick `n1_queue_held_sweep` skips held rows whose blocker ended failed/escalated/skip. For a blocker at `pr` it reads `gh pr view <pr_url> --json state`. Once the user has merged it (`MERGED`), `n1_queue_sync_default` fast-forwards the blocker repo's local default branch (children branch from it) and the row returns to `pending` with Reason `released: <B> merged`. A gh error, a missing `pr_url` or a sync failure leaves it held for the next tick. Rows still held after `subtaskTimeoutMinutes` are skipped (`n1_queue_held_expire`) and stay tagged for a later run. N1 merges a PR only when `autonomy.fullAuto` and `finishWork.mergeOnFinish` are both true (the sweep releases on `MERGED` regardless of who merged), and every child escalation is relayed to the user (`--answer`). Known gap (N1-56, not fixed here): the watch dies on a session or host restart and `queue.notify=desktop` can no-op on WSL, so a critical escalation can sit unrelayed until the user re-arms `--watch` or checks `--status`.
