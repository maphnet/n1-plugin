<!-- Purpose: Detect stack, set up worktree config, enrich CLAUDE.md, and run host-specific checks. -->

## Analyze Repository

Explore the project to detect:

1. **Stack:** Look for `package.json`, `composer.json`, `Cargo.toml`, `go.mod`, `requirements.txt`, `pyproject.toml`, `Gemfile`, `pom.xml`, `build.gradle`, etc.
2. **Docker:** Check for `Dockerfile`, `docker-compose.yml`, `docker-compose.yaml`
3. **Monorepo:** Check for `lerna.json`, `pnpm-workspace.yaml`, `turbo.json`, or multiple `package.json` files
4. **Test runner:** Look in config files and scripts for test commands
5. **Linter/formatter:** Look for `.eslintrc*`, `.prettierrc*`, `phpcs.xml`, `rustfmt.toml`, `.flake8`, etc.
6. **CI/CD:** Check `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, etc.

Read existing CLAUDE.md content to identify what's already documented.

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
yields no command). Store `"after-merge"` as `worktree.cleanup` (default).

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

Detect the host once; the rest of n1-init reads `HOST` where behaviour differs.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
HOST=$(n1_host)
HOST_FILE=$(n1_host_file)
CODEX_CFG="${CODEX_HOME:-$HOME/.codex}/config.toml"
```

**If `HOST` is `claude-code`:** nothing to do; continue.

**If `HOST` is `codex`:** run these checks in order and stop at the first failure.

1. **Hooks trusted.** N1's session-start hook writes `$HOST_FILE`. If the file is missing, or `jq -r .host "$HOST_FILE"` is not `codex`, or `jq -r .version "$HOST_FILE"` differs from `n1_plugin_version`, the hooks have not run for this plugin version. Tell the user:

   ```
   N1's hooks are not trusted yet. Run /hooks, trust the n1 plugin hooks, restart Codex, then run $n1-init again.
   ```
   **STOP.**

2. **Multi-agent tools.** Check `features.multi_agent` and the tool list:
   ```bash
   MA=$(awk '/^\[features\]/{f=1;next} /^\[/{f=0} f && $1=="multi_agent"{print $3}' "$CODEX_CFG" 2>/dev/null)
   ```
   If `MA` is `false`, or `spawn_agent` is absent from your tool list, tell the user:
   ```
   N1 dispatches its personas as Codex subagents, which needs multi-agent tools.
   Add to ~/.codex/config.toml:
     [features]
     multi_agent = true
   then restart Codex and run $n1-init again.
   ```
   **STOP.**

3. **Superpowers present.** If `$brainstorming` is not in your skill list, tell the user: "N1 needs the Superpowers plugin: run `codex plugin add superpowers`, restart Codex, then re-run `$n1-init`." **STOP.**

4. **Persona files.** `ls .codex/agents/n1-*.toml 2>/dev/null | wc -l` must be 11 (one per spawnable persona). If it is 0, the hook could not write into this project: tell the user the path and **STOP**. Otherwise add the generated files to the project `.gitignore` if missing:
   ```bash
   grep -qF '.codex/agents/n1-*.toml' .gitignore 2>/dev/null || { [ -s .gitignore ] && [ -n "$(tail -c1 .gitignore)" ] && echo >> .gitignore; printf '# N1 generated Codex personas\n.codex/agents/n1-*.toml\n' >> .gitignore; }
   ```
   Log: "Added `.codex/agents/n1-*.toml` to .gitignore." (or "already ignored").

5. **Default subagent model.** Read `DEF_MODEL=$(n1_codex_default default_subagent_model)` and `DEF_EFFORT=$(n1_codex_default default_subagent_reasoning_effort)`. If `DEF_MODEL` is empty, tell the user: "Codex has no `[agents] default_subagent_model`; every N1 persona will inherit the session model, which is usually the most expensive one. Set it in ~/.codex/config.toml or pick per-persona models below." Continue to **Agent Model Configuration**, which on Codex is always offered (not only on request).
