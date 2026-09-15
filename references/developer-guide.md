# N1 Plugin — Developer Guide

## Repository Structure

```
github.com/maphnet/n1-plugin/
  skills/     N1 skills (auto-discovered by Claude Code)
  agents/     Agent persona definitions
  hooks/      Event hooks and scripts
  lib/        Shared shell library
  defaults/   Default config files
  .claude-plugin/plugin.json   Plugin manifest (Claude Code)
  .claude-plugin/marketplace.json  Claude Code marketplace manifest
  plugin.json                  Codex plugin manifest
  .agents/plugins/marketplace.json  Codex marketplace
  hooks/codex-hooks.json       Codex hook registration
  references/host-routing.md   Per-host dispatch table
```

See [README.md](../README.md) for user-facing documentation: installation, quick start, skill usage examples, and full feature overview.

## What This Is

N1 is a plugin for Claude Code and Codex that orchestrates the full development cycle (ticket read, analysis, brainstorm, plan, implement, QA, review, [local testing], PR). It uses a **hybrid delegation model**: specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while native N1 skills handle interactive steps (brainstorming, planning, implementation dispatch). It is a **thin controller** (~5-10K tokens per skill): skills load only the memory files they need, spawn agents, and write results back to per-ticket memory.

**n1-start skill layout:** `skills/n1-start/SKILL.md` is a thin dispatcher (<6 KB); each of the 16 pipeline step bodies lives in `skills/n1-start/steps/<step>.md`. Shared orchestrator logic (workspace isolation, telemetry, output gates, resume) lives in `skills/n1-start/procedures/<name>.md`, referenced by steps on demand. Shared review logic lives in `skills/n1-start/review-core.md`.

## Skill Sub-File Architecture

Skills exceeding 6 KB are split into a thin dispatcher + on-demand sub-files:

```
skills/<name>/
  SKILL.md              # Dispatcher (<6 KB)
  steps/
    01-<step-name>.md   # Step file (<15 KB each)
    02-<step-name>.md
  procedures/           # Optional: shared content referenced by >=2 steps
    <procedure-name>.md
  templates/            # Optional: template content
  references/           # Optional: reference docs (e.g., n1-finish)
```

Skills under 6 KB remain in their existing `skills/<name>/SKILL.md` form without sub-files.

**Dispatcher contract (SKILL.md):** Frontmatter + trigger/purpose, numbered step index with one-line descriptions, execution instructions (`Read steps/01-<name>.md and execute`), and minimal global context that every step needs. Hard budget: 6 KB (6,144 bytes). Target: 4-5 KB.

**Step file contract:** Self-contained for its phase — purpose header, full instructions, bash preamble when containing `$N1_ROOT` blocks. Hard budget: 15 KB per file.

**Procedures:** Shared content referenced by 2+ steps within one skill. Loaded by the step that needs it, never by the dispatcher. Content used by only one step stays inline.

**Reference implementations:** `n1-init` (15 step files, dispatcher-only architecture) and `n1-start` (16 step files + 11 procedures for shared orchestrator logic).

**Size enforcement:** `tests/test_skill_size.sh` asserts all SKILL.md files are under 6 KB in CI.

## Stack

- **Runtime:** Bash (hooks), Markdown (skills, agents) — no npm, no Node.js
- **Plugin manifests:** `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` (Claude Code), `plugin.json` + `.agents/plugins/marketplace.json` (Codex); bump all four with `scripts/bump-version.sh`
- **Shared shell helpers:** `lib/host.sh` (host detection, plugin root, headless command), `lib/agent_profiles.py` (Codex persona TOML generator), `lib/transcript_codex.py` (Codex rollout parser), `lib/config.sh` (codex/model resolution), `lib/signals.sh` (signal read/write/gate evaluation), `lib/step.sh` (per-step begin/end helpers: telemetry, frontmatter, signal persistence, decision records), `lib/context.sh` (context-persistence: write/read TIER/TYPE/DESC_QUALITY/LITE_MODE to `ticket-context.sh` so downstream bash snippets can source it instead of re-deriving from frontmatter), `lib/memory.sh` (compaction), `lib/cache.sh` (analysis snapshot I/O and freshness check), `lib/rules.sh` (rules directory resolution, file parsing, agent filtering, injection rendering, deny hook generation), `lib/story.sh` (story orchestrator: service→repo lookup, model pick, toposort, child status/launch)

## Plugin Development

**Always develop via `--plugin-dir`** — it loads the **working tree live** (uncommitted edits included). No install, no commit, no version bump, no reinstall.

```
claude --plugin-dir ~/dev/n1-plugin   # from a test project
# edit files → /reload-plugins → changes are live
```

Do NOT install N1 as a user-scope plugin for local development. A `file://` marketplace install copies from committed git HEAD into a cache, so local edits never show up without commit + version bump + reinstall.

### Notes for any future install/publish

- A `file://` marketplace install copies from committed git **HEAD** into a cache, not the working tree. Refreshing it requires a `version` bump (all four manifests via `scripts/bump-version.sh`) followed by `claude plugin marketplace update n1-plugin` + `claude plugin update n1-plugin@n1-plugin`.
- **Version bumps are mandatory for releases.** Any change that consumers should pick up requires a semver bump in **both** files. Without a bump, `plugin marketplace update` sees no change and consumers stay on the old version.
- Cross-marketplace dependencies require `"marketplace"` in the dependency entry and `"allowCrossMarketplaceDependenciesOn"` in `marketplace.json`.
- `marketplace.json` lives at the repo root (`.claude-plugin/marketplace.json`) so `/plugin marketplace add maphnet/n1-plugin` can find it.
- The `git-subdir` source URL must be the full HTTPS URL (`https://github.com/maphnet/n1-plugin`), not the short `owner/repo` form — the short form resolves to SSH (`git@github.com:`) which fails without configured keys.

## Testing

- **Plugin:** `claude --plugin-dir ~/dev/n1-plugin` from any test project; `/reload-plugins` to pick up edits
- **Always test on a separate repo before committing plugin changes**
- **Dogfooding:** use N1 skills on the N1 repo itself
- Run `bash tests/run.sh` before committing; every lib helper has a test file under `tests/` that builds throwaway git repos in `mktemp -d`.
- Static: `tests/test_host_neutral_skills.sh` fails on any host tool name or host path literal in `skills/` or `agents/`; `tests/test_manifests.sh` checks the four manifest versions.

### Auditing orchestrator delegation

`python3 scripts/audit-orchestrator.py --since <date>` scans local Claude Code transcripts of `/n1:n1-start` sessions and lists main-thread tool calls that touched project files or ran tests/installs/commits, grouped by the preceding agent/skill context. Lines marked `!!` are guardrail violations (see `tests/test_orchestrator_guardrails.sh` for the guardrails). Run it after dogfooding a change to the orchestrator; the goal is `violations: 0` on fresh sessions.

`python3 scripts/benchmark.py` is the orchestrator benchmark behind `/n1:n1-benchmark`. `collect` scans all run records under `~/.n1/*/memory/*/telemetry/runs/`, links each completed run to its Claude Code session transcript (via the raw agents file, falling back to project slug plus time window plus ticket ID), extracts human turns, and classifies them heuristically; ambiguous turns are labeled by a Haiku judge in the skill and passed back via `finalize --labels`, which computes metrics and writes a snapshot. `report` renders per-version tables with bootstrap confidence intervals and deltas against the previous snapshot and the pinned baseline (`baseline set <version>`). State lives in `~/.n1/benchmark/`. Tests: `bash tests/test_benchmark.sh` (integration) and `python3 -m pytest tests/test_benchmark.py` (unit — covers metric classes; not run by `run.sh`).

## Conventions

- **Skill authoring:** Always use `/writing-skills` skill when creating or modifying skills
- Skills: `skills/<name>/SKILL.md` — auto-discovered, invoked as `/n1:<skill-name>`
- Agents: `agents/<name>.md` — frontmatter requires `name`, `description`, `model`; optional `tools` (comma-separated allowlist of tool identifiers). Agents are dispatched as file-based subagents (by name), so Claude Code **enforces** this allowlist at runtime — it is a real capability boundary, not advisory. MCP tools must be named `mcp__<server>__<tool>`; a human label like "Tracker MCP" grants nothing. Omit `tools` entirely to inherit the orchestrator's full tool set — required when an agent needs config-dynamic tracker MCP tools whose names vary by tracker (e.g. product-analyst)
- Hooks: `hooks/hooks.json` — event declarations, scripts in `hooks/`
- One concern per file
- Skills invoke each other via `**REQUIRED SUB-SKILL:** Use plugin:skill-name` directives
- No Co-Authored-By trailers in commits
- **Timestamps:** Never let the model invent a timestamp — it has no clock and will hallucinate. Date-only needs (spec/plan filenames `YYYY-MM-DD`) use the harness-injected `currentDate`. Precise time (time-of-day, durations) must come from the `date` command, e.g. `date -u +%Y-%m-%dT%H:%M:%SZ`. Don't add timestamp fields unless something actually reads them — file mtime already records "last modified".
- **Test & benchmark artifacts:** Tests/benchmarks that verify committed implementation (unit, integration, e2e tied to acceptance criteria) go in the repo and run in CI. Throwaway probes that only answer a current question (approach micro-benchmarks, repro scripts, viability spikes) go under `$N1_HOME/` (external, never committed) — per-ticket `$N1_HOME/memory/<ID>/{benchmarks,tests}/`, or `$N1_HOME/scratch/{benchmarks,tests}/` when there is no ticket memory. When unsure, default to scratch. Bound into the `solution-architect`, `developer`, and `qa-engineer` personas; concrete paths are passed by the skills at spawn time.
- **Design specs:** Design specs produced by brainstorming are written to per-ticket memory (`$N1_HOME/memory/<ID>/brainstorm.md`) — they are working documents, not committed artifacts.
- **Agent spawns pass memory-file paths:** Skills pass the absolute path to each memory file (e.g. `$MEMORY_DIR/ticket.md`) so agents Read them directly. Exception: estimation inline data and the `## Key Decisions`/`## Escalations` slices of overview.md stay inlined. Read-only agents (code-reviewer, security-reviewer, solution-architect) never write memory files; qa-engineer writes `qa.md` itself; developer fix cycles write/replace `## Fix Cycle <N>` sections in `implementation.md` — idempotent upsert, never duplicate.
