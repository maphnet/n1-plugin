<!-- Purpose: Detect stack, set up worktree config, enrich CLAUDE.md, and run host-specific checks. -->

## Analyze Repository

Explore the project to detect:

1. **Stack:** Look for `package.json`, `composer.json`, `Cargo.toml`, `go.mod`, `requirements.txt`, `pyproject.toml`, `Gemfile`, `pom.xml`, `build.gradle`, etc.
2. **Docker:** Check for `Dockerfile`, `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`
3. **Monorepo:** Check for `lerna.json`, `pnpm-workspace.yaml`, `turbo.json`, or multiple `package.json` files
4. **Test runner:** Look in config files and scripts for test commands
5. **Linter/formatter:** Look for `.eslintrc*`, `.prettierrc*`, `phpcs.xml`, `rustfmt.toml`, `.flake8`, etc.
6. **CI/CD:** Check `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, etc.

Read existing CLAUDE.md content to identify what's already documented.

## Consolidated Detection

After analyzing the stack, run these additional detection probes. Detection only -- do NOT ask any questions here. Results are displayed in a consolidated summary and used by later steps to skip redundant discovery.

### Tracker Detection

Scan available tools for tracker MCP patterns (on hosts with deferred tools, search for `mcp__` first per HOST ROUTING):
- Tools matching `mcp__plugin_atlassian_atlassian__*` present -> Jira detected
- Tools matching `mcp__youtrack__*` present -> YouTrack detected
- Both present -> ambiguous (let user choose in step 03)
- Neither present -> no tracker detected

If Jira detected, verify connectivity by calling the get-projects operation (the operation that lists visible projects). Record whether the call succeeded or failed.

Record detection results for step 03: detected tracker type (jira / youtrack / none / ambiguous), MCP server name, connectivity status.

### Observability Detection

Enumerate all available MCP tools, group by server prefix (the segment between `mcp__` and the next `__`). For each server, match tool names against observability category signatures:

| Category | Tool name patterns |
|----------|-------------------|
| Error tracking | `*sentry*`, `*error*issue*`, `*exception*` |
| Log querying | `*loki*`, `*log*query*` |
| Tracing/APM | `*trace*`, `*observation*`, `*session*` combined with `*exception*` |

A server matches a category when 2+ of its tools hit any pattern for that category. Also check if the server name contains a known provider name (sentry, loki, langfuse).

For matched servers, infer environment from server name tokens (`dev`, `prod`, `staging`, etc. -- no token match means `all`). Score confidence: high (name + tools match), medium (tools only), low (few matches).

Record detection results for step 06: list of candidates with server name, category, provider, confidence, inferred environment.

### Startup File Detection

Check the project root for startup files in priority order (highest priority match only):

| Priority | File Pattern | Suggested command |
|----------|-------------|-------------------|
| 1 | `docker-compose.yml` / `docker-compose.yaml` / `compose.yml` / `compose.yaml` | `docker compose up -d` |
| 2 | `Makefile` with targets matching `^(up\|run\|serve\|start\|dev):` | `make <first match>` |
| 3 | `package.json` with `dev` or `start` in scripts | `npm run dev` |
| 4 | `manage.py` | `python manage.py runserver` |
| 5 | `Procfile` | command from `web:` line |

Record detection results for step 08: matched file (if any), suggested command, other detected files.

### Detection Summary

Display all detection results as one consolidated block before any questions:

```
Detected environment:
  Stack: <language(s)>, <framework>, <test runner>, <linter>, <CI system>
  Docker: <yes (compose) / yes / no>
  Tracker: <Jira (MCP connected) / YouTrack (MCP found) / None detected>
  Observability: <provider [confidence], ...> or "None detected"
  Startup: <file> -> <command> or "None detected"
  Worktree setup: <command> or "none"

Setup will proceed based on these detections.
```

Then continue to **Worktree Setup Detection** and **Enrich CLAUDE.md**.

## Worktree Setup Detection

Auto-detect the appropriate setup command for new worktrees based on the project's package manager:

| Detected file | Suggested command |
|---|---|
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package.json` (no lockfile) | `npm install` |
| `Cargo.toml` | `cargo fetch` |
| `requirements.txt` | `pip install -r requirements.txt` |
| `go.mod` | `go mod download` |
| None of the above | `null` (no setup) |

Silently derive the setup command from the detection table above — do NOT prompt.
Store the derived value as `worktree.setup` in config (store `null` when the table
yields no command).

The command is reported (not asked) in the init summary — see the summary block below,
which already prints `Worktree setup: <command or "none">`. Non-standard projects
(monorepo bootstrap, `make setup`, private-registry auth, env files, DB migrations)
override `worktree.setup` in `config.json` after init.

## Enrich CLAUDE.md (if gaps found)

Compare what was detected vs. what's documented in CLAUDE.md.

If gaps exist, propose additions as a structured block. **Only add tool-agnostic information** — no N1-specific config in CLAUDE.md.

Present proposed additions to the user:
```
I found the following gaps in your CLAUDE.md:

## Proposed additions:

### Commands
docker compose exec app php artisan test
docker compose exec app ./vendor/bin/phpunit
npm run dev

### Project Structure
- app/Http/Controllers/ — HTTP controllers
- app/Services/ — Business logic
...

Add these to CLAUDE.md?
1 — Yes
2 — No
3 — Edit first
```

If approved (1), append to CLAUDE.md. If edit (3) — ask what to change first.

## Host Setup

Host is fixed to Claude Code; nothing to detect or set up here.
