
Run `n1_config_val '.release.enabled'` (default: `false`).

> The gate key (`release.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

**If `release.enabled` is `false`:**
- Full pipeline mode: skip silently to FINALIZE MEMORY.
- Step mode: emit `outcome: "skip"` with `next_step: null` and stop.

**REQUIRED SUB-SKILL:** Use n1:n1-release to create the git tag and GitHub Release.

The n1-release skill works from the current branch and config. It:
1. Checks the current branch against the default branch
2. Reads the version from `.claude-plugin/plugin.json`
3. Shows a confirmation gate with version, previous tag, and precondition status
4. Creates an annotated git tag and GitHub Release (or walks through a custom procedure)
5. Posts a tracker comment best-effort

**Outcome mapping (step mode):**
- Release created (or already exists) → `outcome: "pass"`, `next_step: null`
- Gate closed → `outcome: "skip"`, `next_step: null`
- Release failed or user aborted → `outcome: "fail"`, `next_step: null`

> **After `n1:n1-release` returns, IMMEDIATELY continue to FINALIZE MEMORY with the release result noted — do NOT write a summary message or yield to the user.**

**Step result (step mode):**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_emit_step_result "release" "pass" "null" "null"
```
