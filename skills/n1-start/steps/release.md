
Run `n1_config_val '.release.enabled'` (default: `false`).

> The gate key (`release.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `release.enabled` is `false`:** skip silently to FINALIZE MEMORY.

**REQUIRED SUB-SKILL:** Use n1:n1-release to create the git tag and GitHub Release.

The n1-release skill works from the current branch and config. It:
1. Checks the current branch against the default branch
2. Reads the version from `.claude-plugin/plugin.json`
3. Shows a confirmation gate with version, previous tag, and precondition status
4. Creates an annotated git tag and GitHub Release (or walks through a custom procedure)
5. Posts a tracker comment best-effort

> **After `n1:n1-release` returns, IMMEDIATELY continue to FINALIZE MEMORY with the release result noted — do NOT write a summary message or yield to the user.**
