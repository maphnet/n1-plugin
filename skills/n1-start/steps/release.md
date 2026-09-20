
Run `n1_config_val '.release.enabled'` (default: `false`).

```bash
source "$N1_ROOT/lib/preamble.sh"
GATE_ENABLED=$(n1_config_val '.release.enabled' 2>/dev/null || echo 'false')
n1_record_decision release-gate "$( [ "${GATE_ENABLED:-false}" = "true" ] && echo true || echo false )" '{"config":"release.enabled"}' "enabled=${GATE_ENABLED:-false}"
```

> The gate key (`release.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `release.enabled` is `false`:** skip silently to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-release to create the git tag and GitHub Release.

The n1-release skill works from the current branch and config. It:
1. Checks the current branch against the default branch
2. Reads the version via `release.versionSource` (auto-detected: package.json, the Claude plugin manifest, pyproject.toml, Cargo.toml, VERSION)
3. Shows a confirmation gate with version, previous tag, and precondition status
4. Creates an annotated git tag and GitHub Release (or walks through a custom procedure)
5. Posts a tracker comment best-effort

> **After `n1:n1-release` returns, IMMEDIATELY continue to FINALIZE MEMORY with the release result noted — do NOT write a summary message or yield to the user.**
