# CLAUDE.md

This file provides guidance to Claude Code when working with the n1-plugin repository.

## Language Policy

ALL code, documentation, skills, agents, hooks, comments, and commit messages MUST be in English.
Russian is prohibited in any committed file.

## What This Is

N1 is a plugin for Claude Code 2.1+ and Codex CLI 0.154+ that orchestrates the full development cycle using a **hybrid delegation model**: specialized agent personas handle autonomous work, while native N1 skills handle interactive steps. It is a **thin controller** (~5-10K tokens per skill).

See [references/architecture.md](references/architecture.md) for pipeline internals, signal-driven gating, type registry, and all subsystem details.
See [references/developer-guide.md](references/developer-guide.md) for project structure, plugin development workflow, and authoring conventions.

When you need tracker MCP operation names or routing → `references/architecture.md § Tracker Routing`
When you need observability provider config → `references/architecture.md § Observability`
When you need cross-repo project setup → `references/architecture.md § Cross-Repo Awareness`
When you need the Telemetry Analyzer CLI → `references/developer-guide.md § Telemetry Analyzer`

## Stack

- **Runtime:** Bash (hooks), Markdown (skills, agents) — no npm, no Node.js
- **Shared shell helpers:** `lib/host.sh` (host detection, plugin root, headless command), `lib/config.sh`, `lib/signals.sh`, `lib/step.sh` (per-step begin/end helpers), `lib/context.sh` (context-persistence: write/read TIER/TYPE/DESC_QUALITY/LITE_MODE/SIMPLE_PATH across bash snippets), `lib/memory.sh`, `lib/cache.sh`, `lib/rules.sh`, `lib/fingerprints.sh`, `lib/queue.sh`, `lib/related.sh`
- **Host layer:** skill text is host-neutral; per-host syntax lives in `references/host-routing.md` and is injected by the session-start hook as HOST ROUTING. `tests/test_host_neutral_skills.sh` rejects host literals in `skills/` and `agents/`.

## Plugin Development

**Always develop via `--plugin-dir`** — loads the working tree live (uncommitted edits included):

```
claude --plugin-dir ~/dev/n1-plugin   # from a test project; /reload-plugins to pick up edits
```

Codex: `codex plugin marketplace add <path-to-checkout>` then `codex plugin add n1@n1`; re-add after edits (Codex copies the plugin).

Do NOT install N1 as a user-scope plugin for local development.

## Testing

- Test on a separate repo before committing; `/reload-plugins` to pick up edits
- Dogfooding: use N1 skills on the N1 repo itself

## Conventions

- **Skill authoring:** Always use `/writing-skills` skill when creating or modifying skills. Never name a host tool (Agent, AskUserQuestion, ToolSearch, Skill, spawn_agent) in skill text; write "dispatch persona", "ask the user", "invoke skill" and let HOST ROUTING resolve it.
- **Timestamps:** Never invent a timestamp. Date-only: use harness-injected `currentDate`. Time: `date -u +%Y-%m-%dT%H:%M:%SZ`. Don't add timestamp fields unless something reads them.
- **Test/benchmark artifacts:** committed tests go in repo; throwaway probes go under `$N1_HOME/` (per-ticket `memory/<ID>/{benchmarks,tests}/` or `scratch/{benchmarks,tests}/`)
- **Design specs:** Design specs produced by brainstorming are written to per-ticket memory (`$N1_HOME/memory/<ID>/brainstorm.md`) — working documents, not committed artifacts
- **Agent spawns pass memory-file paths:** Skills pass absolute paths so agents `Read` files directly. Read-only agents (code-reviewer, security-reviewer) never write memory; solution-architect writes `analysis.md` + snapshot (via Bash, ref #44657); qa-engineer writes `qa.md`; developer writes `## Fix Cycle <N>` sections in `implementation.md` (idempotent upsert)

## N1_HOME Resolution

Resolution priority (all paths go through `n1_home()` in `lib/config.sh`):

1. `$N1_HOME` env var — if set, used as-is (platform-local override)
2. Auto-derive from repo name: `$HOME/.n1/<slug>/` (if directory exists). Tries remote-URL slug (`git remote get-url origin` basename) first, then directory-name slug (`git rev-parse --show-toplevel` basename); both lowercased and sanitized; returns whichever matches an existing directory.
3. `git config n1.home` — legacy backward compat; expand `~`; WSL `wslpath` conversion
4. In-repo `.n1/` fallback

**Skills:** start bash snippets with `source "$N1_ROOT/lib/preamble.sh"` — this provides `N1_ROOT`, sources `lib/config.sh` and other helpers, and sets `N1_HOME`. The preamble template is in `references/host-routing.md`.

Config: `$N1_HOME/config.json`

## Escalation Safety

Always escalate: security, architecture, public API changes.
Release is never automatic — n1-release confirmation gate is unconditional.
`tailChain` is `suggest` in all autonomy modes — release must be triggered manually.
Headless runs (`N1_HEADLESS=1`) never auto-resolve unconditional gates — they pause with a recorded escalation and a tracker comment.

## Git

- Default branch: `main`
- Commit style: imperative mood, English
- No Co-Authored-By trailers
- **Version bump mandatory on every task branch:** run `scripts/bump-version.sh <new>` (updates the four manifests: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `plugin.json`, `.agents/plugins/marketplace.json`; `tests/test_manifests.sh` asserts they match). Commit as `chore: bump version to <new> (<ID>)`.
- **Workspace isolation:** worktree at `<main-checkout>/.claude/worktrees/<ID>/` (default). `n1-pr` performs `git push -u origin <branch>`; `n1-finish` removes the worktree after merge when `worktree.cleanup` is `"after-merge"` or `"after-pr"` (alias).
