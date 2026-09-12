# Runtime review preview: package, enable, and remove

The runtime review preview is an opt-in, read-only qualification artifact. The
packager copies files to a new directory; it does not install a plugin, edit a
host configuration, trust hooks, run hooks, install Pi dependencies, or start a
model. The packages shipped at this revision remain unsupported until their
required native capabilities have passing disposable-environment evidence.

## Build and relocate a package

Choose a unique build ID and an absolute destination outside this source tree.
The destination must not already exist or be a symlink. A normal scratch layout
is `$N1_HOME/scratch/reviews/packages/<build-id>/<host>`:

```bash
python3 scripts/package-review-preview.py \
  --host claude-code \
  --destination /absolute/n1-home/scratch/reviews/packages/<build-id>/claude-code
```

Valid host values are `claude-code`, `codex`, and `pi`. Build each host in its
own new directory. The resulting `package-evidence.json` identifies the host
and records the SHA-256 of every packaged file. It deliberately contains no
credentials, environment values, user configuration, or file contents.

The Claude Code package preserves the existing `n1` plugin identity and its
normal `.claude-plugin/`, `agents/`, `hooks/`, `skills/`, `lib/`, and pipeline
resources while adding the runtime adapter. Codex and Pi packages preserve
`adapters/<host>/preview/`, `lib/`, and `runtime/review/`. Move the whole
assembled tree before enabling it. Adapter paths
must continue to point into that tree; they must not point back to this checkout
or an installation cache. Moving it after configuration changes the effective
configuration, so update every absolute reference and repeat capability
qualification. Never build over an old package.

## Configuration and model policy

Add preview model policy only to the N1 configuration belonging to the
disposable test project. Every role is required. For example, Codex inheritance
uses this namespace and value:

```json
{"runtimePreview":{"hosts":{"codex":{"models":{
  "code-reviewer":{"mode":"inherit"},
  "security-reviewer":{"mode":"inherit"},
  "review-verifier":{"mode":"inherit"}
}}}}}
```

Use `runtimePreview.hosts.claude-code.models` for Claude Code and
`runtimePreview.hosts.pi.models` for Pi. `mode: "inherit"` means that the
adapter must observe and record the effective native provider, model, and
effort; it does not authorize a silent default. An explicit policy must name a
provider and model and must pass that host's native availability checks.

Before changing anything, save or compare the disposable project's host and N1
configuration. Compare it again after enablement and after removal. A repeated
enable must not replace unrelated settings or add a second hook registration.
Do not merge preview entries into production or user/global configuration.

## Capability report and stop conditions

A capability report records `host`, `hostVersion`, package, configuration, and
tool-inventory digests, `capabilities`, `models`, and `reasons`. Each capability
has status `available`, `unavailable`, or `unverified` plus native evidence.
All required capabilities—read/search enforcement, isolated context, and
lifecycle control—must be `available` for the exact host version, package,
configuration, tools, and model policy in use. A changed digest makes the
evidence stale.

`unavailable`, `unverified`, missing, malformed, or stale evidence means the
configuration is **unsupported**. It is not a degraded review and must stop
before source preparation or worker dispatch. Never convert reviewer prose,
static configuration, or model refusal into capability evidence.

## Enable and check Claude Code

Use a disposable project and the host's explicit local package option. The
assembled artifact is the existing `n1` plugin at version `3.0.0`, not a second
plugin identity. Do not load it alongside another `n1` installation in the
same disposable session:

```bash
claude --plugin-dir /absolute/package
```

Inspect the loaded plugin path and trust state, confirm that only this `n1`
package is selected, and run its packaged preflight. Existing N1 commands use
their normal names and installation layout. The runtime currently has
no registered hooks and its packaged qualification record is unverified, so it
must report unsupported without dispatch. Do not enable a hook unless a later
qualification proves worker identity, per-run path binding, trust, and
pre-first-tool ordering.

The only accepted invocation syntax is:

```text
/n1-review-runtime owner/repo#123
```

A no-argument, local-path, branch-only, or malformed invocation must fail.

## Enable and check Codex

Use a dedicated disposable `CODEX_HOME` and inspect the effective sandbox,
permissions, MCP/connectors, tool inventory, instruction hierarchy, and plugin
trust before qualification. Do not use a trust bypass, sandbox bypass, or the
normal user `~/.codex` configuration.

The installed `codex-cli 0.154.0` has no direct option that loads an arbitrary
local `.codex-plugin/plugin.json` path. Its native package-loading boundary is
a marketplace-backed plugin install. Create a disposable local marketplace
whose single source points at the packaged adapter; the symlink is outside the
package, so `package-evidence.json` remains valid:

```bash
mkdir -p /absolute/n1-runtime-marketplace/.agents/plugins \
  /absolute/n1-runtime-marketplace/plugins
ln -s /absolute/package/adapters/codex/preview \
  /absolute/n1-runtime-marketplace/plugins/runtime-review
```

```text
/absolute/n1-runtime-marketplace/
├── .agents/plugins/marketplace.json
└── plugins/runtime-review -> /absolute/package/adapters/codex/preview
```

The marketplace file is:

```json
{
  "name": "n1-review-runtime",
  "interface": {"displayName": "N1 Review Runtime"},
  "plugins": [{
    "name": "runtime-review",
    "source": {"source": "local", "path": "./plugins/runtime-review"},
    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
    "category": "Productivity"
  }]
}
```

Register that marketplace and install the plugin only in the disposable home:

```bash
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin marketplace add /absolute/n1-runtime-marketplace
CODEX_HOME=/absolute/disposable-codex-home \
  codex plugin add runtime-review@n1-review-runtime
```

Run `codex plugin add runtime-review@n1-review-runtime` a second time with the same
`CODEX_HOME`, then use `codex plugin list --json` to confirm there is exactly
one enabled `runtime-review@n1-review-runtime` registration. Confirm the single cached
packaged `hooks.json` is still `{"hooks": {}}`, so there are zero preview hook
registrations, and that no unrelated hook was duplicated. A duplicate plugin or
hook registration is unsupported.

The native plugin install loads the packaged skill and manifest; it does
**not** install or bind custom agents. As a separate configuration step, add
only these entries to the disposable `$CODEX_HOME/config.toml`, replacing
`/absolute/package` with the relocated package root:

```toml
[agents.n1_runtime_code_reviewer]
config_file = "/absolute/package/adapters/codex/preview/agents/n1_runtime_code_reviewer.toml"

[agents.n1_runtime_security_reviewer]
config_file = "/absolute/package/adapters/codex/preview/agents/n1_runtime_security_reviewer.toml"

[agents.n1_runtime_review_verifier]
config_file = "/absolute/package/adapters/codex/preview/agents/n1_runtime_review_verifier.toml"
```

Add each table only if it is absent. Repeating enablement must leave one copy of
each table and must preserve all unrelated agents, hooks, comments, and
settings. Validate that disposable configuration with the qualified Codex
version and confirm each exact profile binding. The current package registers
no preview hook and has no proven native role/profile dispatch binding, so it
remains unsupported. A generic spawned agent is not a substitute.

The only accepted invocation syntax is:

```text
$n1-review-runtime owner/repo#123
```

A no-argument invocation must fail.

## Enable and check Pi

Pi dependencies are intentionally absent from assembled packages. The selected
qualification lane uses Node `24.19.0` (the package permits `>=24.19.0 <25`) and
the pinned Pi package `0.85.1`. In the relocated package only, make dependency
installation a separate, explicit action:

```bash
npm --prefix /absolute/package/adapters/pi/preview \
  ci --ignore-scripts --no-audit --no-fund
```

Then load the local extension explicitly with the package-local pinned CLI;
`--no-extensions` disables discovery while the qualified host still loads the
named `--extension`:

```bash
node /absolute/package/adapters/pi/preview/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js \
  --no-extensions \
  --extension /absolute/package/adapters/pi/preview/extensions/review.ts
```

Confirm the exact Node/Pi versions, explicit extension path, disabled resource
discovery, effective provider/model/effort, tool allowlist, and guard loading.
The current package has unverified native guard ordering and context isolation,
so it remains unsupported before a model worker starts. Pi tests and dependency
installation are a separate required release lane; Claude packaging and tests
must work without Node or Pi.

The only accepted invocation syntax is:

```text
/n1-review-runtime owner/repo#123
```

A no-argument invocation must fail.

## Outputs and incomplete reviews

Controller state, native receipts, raw bounded worker output, and the final
local report belong under `$N1_HOME/scratch/reviews/<run-id>/`. Packages belong
under `$N1_HOME/scratch/reviews/packages/<build-id>/`; they do not share ticket
state, production telemetry locks, or `active-run.json`.

The preview may render a local advisory report only after all required stages
complete. Unsupported, failed, timed-out, cancelled, interrupted, or
unreconciled work is incomplete. Preserve that outcome and its scratch evidence;
never synthesize an approval. The preview must not apply fixes, post GitHub
comments or reviews, update a tracker, alter ticket state, commit, or push.

## Disable and remove the preview

Preserve `$N1_HOME/scratch/reviews/<run-id>/` evidence before changing the
runtime setup. Stop active preview workers and wait for native terminal receipts.
Then use only the host-specific opt-in boundary:

- Claude Code: start the next session without the preview `--plugin-dir` value.
- Codex: run the native inverse operations against the same disposable home:

  ```bash
  CODEX_HOME=/absolute/disposable-codex-home \
    codex plugin remove runtime-review@n1-review-runtime
  CODEX_HOME=/absolute/disposable-codex-home \
    codex plugin marketplace remove n1-review-runtime
  ```

  Then remove only the three `agents.n1_runtime_*` tables shown above from
  that `$CODEX_HOME/config.toml`. Remove the exact disposable marketplace
  wrapper or its `plugins/runtime-review` symlink only after confirming it contains no
  unrelated entries. Keep the relocated package and its
  `package-evidence.json` with the preserved scratch evidence.
- Pi: start the next session without the preview `--extension` value. If the
  package-local dependency install is no longer needed, uninstall only
  `@earendil-works/pi-coding-agent` from that exact preview prefix with npm, or
  retire the exact generated preview package through the operating system's
  recoverable trash mechanism.

Compare the disposable configuration with its pre-enable state. Existing
`AGENTS.md`, `CLAUDE.md`, unrelated hooks/settings, N1 production plugin and
configuration, production `.claude-plugin`, `agents/`, `hooks/`, `skills/`,
pipeline files, scratch evidence, and ticket state must remain unchanged. Do
not prescribe or run recursive deletion against a home directory, repository,
`.claude`, `.codex`, `.n1`, `scratch`, or another broad parent directory.

These Codex commands are qualified only for the installed `codex-cli 0.154.0`
surface. If the target installed version does not expose `plugin marketplace
add`, `plugin add`, `plugin remove`, and `plugin marketplace remove`, or if any
command or the exact post-install/post-removal comparison fails, there is no
qualified native package-loading lifecycle for that host. Stop as unsupported;
do not copy the skill into a discovery directory or invent a manifest flag.
