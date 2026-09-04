# N1 Plugin — Developer Guide

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

See [README.md](../README.md) for user-facing documentation: installation, quick start, skill usage examples, and full feature overview.

## What This Is

N1 is a Claude Code plugin that orchestrates the full development cycle (ticket read, analysis, brainstorm, plan, implement, QA, review, [local testing], PR). It uses a **hybrid delegation model**: 9 specialized agent personas handle autonomous work (analysis, QA, review, fixes, PR content), while [Superpowers](https://github.com/obra/superpowers) ^5.0 sub-skills handle interactive steps (brainstorming, planning, implementation dispatch via SDD). It is a **thin controller** (~5-10K tokens per skill): skills load only the memory files they need, spawn agents or invoke Superpowers, and write results back to per-ticket memory.

**n1-start skill layout (v2.12.0):** `skills/n1-start/SKILL.md` is a thin dispatcher; each of the 16 pipeline step bodies lives in `skills/n1-start/steps/<step>.md` (one file per step name). Shared review logic (diff-surface classification, Codex probe + CODEX_ACTIVE gating, code-reviewer scope-narrowing) lives in `skills/n1-start/review-core.md`, referenced by both `steps/review.md` and `skills/n1-review/SKILL.md`.

## Stack

- **Runtime:** Bash (hooks), Markdown (skills, agents) — no npm, no Node.js
- **Plugin manifest:** `.claude-plugin/plugin.json`
- **Marketplace manifest:** `.claude-plugin/marketplace.json` (repo root — for `marketplace add`)
- **Dependency:** Superpowers plugin >=5.0
- **Shared shell helpers:** `lib/config.sh` (codex/model resolution), `lib/signals.sh` (signal read/write/gate evaluation), `lib/memory.sh` (compaction), `lib/cache.sh` (analysis snapshot I/O and freshness check), `lib/rules.sh` (rules directory resolution, file parsing, agent filtering, injection rendering, deny hook generation)

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

### Auditing orchestrator delegation

`python3 scripts/audit-orchestrator.py --since <date>` scans local Claude Code transcripts of `/n1:n1-start` sessions and lists main-thread tool calls that touched project files or ran tests/installs/commits, grouped by the preceding agent/skill context. Lines marked `!!` are guardrail violations (see `tests/test_orchestrator_guardrails.sh` for the guardrails). Run it after dogfooding a change to the orchestrator; the goal is `violations: 0` on fresh sessions.

`python3 scripts/benchmark.py` is the orchestrator benchmark behind `/n1:n1-benchmark`. `collect` scans all run records under `~/.n1/*/memory/*/telemetry/runs/`, links each completed run to its Claude Code session transcript (via the raw agents file, falling back to project slug plus time window plus ticket ID), extracts human turns, and classifies them heuristically; ambiguous turns are labeled by a Haiku judge in the skill and passed back via `finalize --labels`, which computes metrics and writes a snapshot. `report` renders per-version tables with bootstrap confidence intervals and deltas against the previous snapshot and the pinned baseline (`baseline set <version>`). State lives in `~/.n1/benchmark/`. Tests: `bash tests/test_benchmark.sh`.

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
- **Agent spawns pass memory-file paths:** Skills pass the absolute path to each memory file (e.g. `$MEMORY_DIR/ticket.md`) so agents Read them directly. Exception: estimation inline data and the `## Key Decisions`/`## Escalations` slices of overview.md stay inlined. Read-only agents (code-reviewer, security-reviewer, codex-reviewer, solution-architect) never write memory files; qa-engineer writes `qa.md` itself; developer fix cycles write/replace `## Fix Cycle <N>` sections in `implementation.md` — idempotent upsert, never duplicate.
