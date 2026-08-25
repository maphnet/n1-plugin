# CLAUDE.md

This file provides guidance to Claude Code when working with the n1-plugin repository.

## Language Policy

ALL code, documentation, skills, agents, hooks, comments, and commit messages MUST be in English.
Russian is prohibited in any committed file.

## What This Is

N1 is a Claude Code plugin that orchestrates the full development cycle using a **hybrid delegation model**: specialized agent personas handle autonomous work, while [Superpowers](https://github.com/obra/superpowers) ^5.0 sub-skills handle interactive steps. It is a **thin controller** (~5-10K tokens per skill).

See [references/architecture.md](references/architecture.md) for pipeline internals, step mode, signal-driven gating, type registry, and all subsystem details.
See [references/developer-guide.md](references/developer-guide.md) for project structure, plugin development workflow, and authoring conventions.

## Stack

- **Runtime:** Bash (hooks), Markdown (skills, agents) — no npm, no Node.js
- **Dependency:** Superpowers plugin >=5.0
- **Shared shell helpers:** `lib/config.sh`, `lib/signals.sh`, `lib/memory.sh`, `lib/cache.sh`, `lib/rules.sh`

## Plugin Development

**Always develop via `--plugin-dir`** — loads the working tree live (uncommitted edits included):

```
claude --plugin-dir ~/dev/n1-plugin   # from a test project; /reload-plugins to pick up edits
```

Do NOT install N1 as a user-scope plugin for local development.

## Testing

- Test on a separate repo before committing; `/reload-plugins` to pick up edits
- Dogfooding: use N1 skills on the N1 repo itself

## Conventions

- **Skill authoring:** Always use `/writing-skills` skill when creating or modifying skills
- **Timestamps:** Never invent a timestamp. Date-only: use harness-injected `currentDate`. Time: `date -u +%Y-%m-%dT%H:%M:%SZ`. Don't add timestamp fields unless something reads them.
- **Test/benchmark artifacts:** committed tests go in repo; throwaway probes go under `$N1_HOME/` (per-ticket `memory/<ID>/{benchmarks,tests}/` or `scratch/{benchmarks,tests}/`)
- **Design specs:** `docs/superpowers/specs/` is gitignored — do not commit or force-add
- **Agent spawns pass memory-file paths:** Skills pass absolute paths so agents `Read` files directly. Read-only agents (code-reviewer, security-reviewer, codex-reviewer) never write memory; solution-architect writes `analysis.md` + snapshot (via Bash, ref #44657); qa-engineer writes `qa.md`; developer writes `## Fix Cycle <N>` sections in `implementation.md` (idempotent upsert)

## N1_HOME Resolution

**Skills:** `git config n1.home`; expand `~`; fall back to `.n1/` in project root.

**Hooks bash preamble:**
```bash
N1_HOME=$(git config n1.home 2>/dev/null || true)
if [ -n "$N1_HOME" ]; then
    N1_HOME="${N1_HOME/#\~/$HOME}"
else
    N1_HOME="${PWD}/.n1"
fi
```

Config: `$N1_HOME/config.json`

## Tracker Routing

Tool names constructed as `mcp__<tracker.mcp>__<operation>` — never hardcoded.

| Tracker | type | mcp value | Key operations |
|---------|------|-----------|---------------|
| Jira | `jira` | `plugin_atlassian_atlassian` | `getJiraIssue`, `transitionJiraIssue`, `addCommentToJiraIssue`, `getTransitionsForJiraIssue`, `atlassianUserInfo` (getCurrentUser), `editJiraIssue` (assign, editTicket), `createConfluencePage` (createArticle), `getConfluencePage` (getArticle), `updateConfluencePage` (updateArticle) |
| Jira (versions) | `jira` | `<tracker.versionMcp>` | `jcm_createVersion` (createVersion), `jcm_releaseVersion` (releaseVersion), `jcm_listVersions` (listVersions) — routed via `tracker.versionMcp` (user-specific jc-mcp server name, e.g. `publius-jc-mcp`) |
| YouTrack | `youtrack` | `youtrack` | `get_issue`, `update_issue` (moveStatus, editTicket), `add_issue_comment`, `get_issue_comments`, `get_current_user` (getCurrentUser), `change_issue_assignee` (assign), `create_article` (createArticle), `get_article` (getArticle), `update_article` (updateArticle) |

### Knowledge Base

Optional KB article support for on-demand publishing. Gated on `kb.enabled` in `$N1_HOME/config.json` (default `false`). Configured by `n1-init` during tracker setup — Jira detects Confluence spaces, YouTrack detects `create_article` tool availability.

KB operations use the abstract names (`createArticle`, `getArticle`, `updateArticle`) in the tracker operations map. No dedicated skill — the model uses KB ops directly when the user asks to publish content.

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `kb.enabled` | boolean | `false` | Master gate |
| `kb.spaceId` | string | — | Confluence space ID (Jira only) |
| `kb.spaceKey` | string | — | Confluence space key for display (Jira only) |

Jira also requires `tracker.cloudId` (detected during tracker setup) for all Confluence operations. YouTrack uses `tracker.projectKey` — no extra config needed.

The session-start hook injects KB ROUTING context when enabled, providing the model with space/project defaults for KB calls.

### Observability

Optional multi-provider observability integration for querying logs, errors, and traces during investigations and on-demand. Config-driven via `observability` block in `$N1_HOME/config.json`. Environment-first grouping: each environment maps provider names to self-contained `{ mcp, operations }` entries. When `observability` is `null` or absent, the feature is fully disabled.

| Provider | Example mcp value | Key operations |
|----------|-------------------|----------------|
| Sentry | `publius-sentry` | `search_sentry_issues` (searchIssues) |
| Loki | `publius-loki-mcp` | `loki_query` (query), `loki_label_names` (labelNames), `loki_label_values` (labelValues) |
| Langfuse | `publius-dev-langfuse-mcp` | `find_exceptions` (findExceptions), `fetch_traces` (fetchTraces), `get_session_details` (getSessionDetails) |

**Config:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `observability.default` | string | — | Environment name used for pipeline auto-enrichment |
| `observability.environments` | object | — | Env name → provider name → `{ "mcp": "<server-name>", "operations": { ... } }` |

Provider keys are human-readable labels. Operations may differ per environment for the same provider. Providers with intake support (e.g. Sentry) carry additional fields (`urlPattern`, `orgSlug`, `projectSlug`) on the provider entry for URL detection. Adding a new provider requires zero code changes — just a config entry.

The session-start hook injects OBSERVABILITY ROUTING context when configured, providing the model with per-environment MCP prefixes, providers, and available operations.

## Escalation Safety

Always escalate: security, architecture, public API changes.
Release is never automatic — `tailChain` scope ends at finish; n1-release confirmation gate is unconditional.

## Git

- Default branch: `main`
- Commit style: imperative mood, English
- No Co-Authored-By trailers
- **Version bump mandatory on every task branch:** bump minor version in BOTH `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` (they must match). Commit as `chore: bump version to <new> (<ID>)`.
- **Workspace isolation:** worktree at `<main-checkout>/.claude/worktrees/<ID>/` (default). `n1-pr` performs `git push -u origin <branch>`; `n1-finish` removes the worktree after merge when `worktree.cleanup` is `"after-merge"` or `"after-pr"` (alias).
