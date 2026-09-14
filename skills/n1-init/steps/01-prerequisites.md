<!-- Purpose: Detect existing configuration, handle migration, and determine setup mode (fresh/upgrade/skip). -->

## Prerequisites

Check if CLAUDE.md exists in the project root:
- **If missing:** Create a minimal `CLAUDE.md` with `# <project-name>` (derived from the directory name or `package.json`/`Cargo.toml`/etc. if available). Log: "Created a minimal CLAUDE.md — I'll enrich it after analyzing the repo." Continue.
- **If exists:** Continue.

### Detect Existing Configuration

Check for N1 configuration in priority order:

1. **New-format config:** Resolve N1_HOME by running the preamble line from `references/host-routing.md` followed by `source "$N1_ROOT/lib/config.sh" && n1_home`. If it returns a path, check if `$N1_HOME/config.json` exists.
   - **If exists:** Load the config and check for missing top-level keys against the **Expected Config Keys** list in the dispatcher SKILL.md. Then branch:
     - **If no missing keys:** Tell the user: "N1 is already configured for this project (state at `$N1_HOME`). Current config:" then show the config. Ask: "Reconfigure? **1** — Yes / **2** — No". If no — **STOP.** If yes — continue to **Analyze Repository**, then walk all config sections using their "On reconfiguration" sub-flows.
     - **If missing keys found:** Tell the user: "N1 is already configured for this project (state at `$N1_HOME`). Current config:" then show the config. Then show:

       ```
       N1 config is missing sections added in newer versions:
         → <comma-separated missing key names>

       1 — Add missing sections (walks through only the new ones)
       2 — Full reconfigure (re-ask everything)
       3 — Skip
       ```

       - **If 1 (Add missing sections):** Run the **Targeted Upgrade** flow below.
       - **If 2 (Full reconfigure):** Continue to **Analyze Repository**, then walk all config sections using their "On reconfiguration" sub-flows (which now handle absent blocks via the implicit-else fix).
       - **If 3 (Skip):** **STOP.**

2. **Old-format config (migration candidate):** Check if `.n1/n1.config.json` exists on disk.
   - **If exists:** Proceed to **Migration Flow** below.

3. **No config found:** Continue with **Fresh Setup**.

### Expected Config Keys

The canonical set of top-level config keys. Used by the completeness check to detect missing sections. When adding a new config section to n1-init, add its key here.

```
worktree, tracker, git, ticketTagging, observability, estimation,
localTesting, finishWork, release, testCoverage, telemetry,
analysisCache, rules, escalation, autonomy, review, ciChecks, planReview, memory, models
```

### Targeted Upgrade

For each missing key, run that key's **fresh-setup** flow (the primary section, not the "On reconfiguration" variant). Process missing keys in the same order as the full n1-init flow:

1. `tracker` → **Tracker Setup**
2. `git` → **Git Configuration**
3. `ticketTagging` → **Ticket Tagging Configuration** (fresh-setup portion)
4. `observability` → **Observability Configuration** (fresh-setup portion)
5. `estimation` → **Estimation Configuration** (fresh-setup portion)
6. `localTesting` → **Local Testing Configuration** (fresh-setup portion)
7. `finishWork` → **Finish Work Configuration** (fresh-setup portion)
8. `release` → **Release Configuration** (fresh-setup portion)
9. `testCoverage` → **Test Coverage Configuration** (fresh-setup portion)
10. `telemetry` → **Telemetry Configuration** (fresh-setup portion)
11. `analysisCache` → **Analysis Cache Configuration** (fresh-setup portion)
12. `rules` → **Rules Configuration** (fresh-setup portion)
13. `worktree` → **Worktree Setup Detection** (silent detection, no prompt)
14. `escalation` → **Escalation Defaults** (writes defaults silently)
15. `autonomy` → **Autonomy Configuration** (fresh-setup: offer hands-off / interactive, write single `mode` key)
16. `review`, `ciChecks`, `planReview`, `memory`, `models` → write defaults silently (see **Write Configuration and Structure** for default values)

Skip keys that are already present in the config. Preserve all existing keys and their values untouched.

**Special case:** If `rules` is among the missing keys, run **Analyze Repository** first (rules starter generation needs detection results). Otherwise skip Analyze Repository and CLAUDE.md enrichment.

After all missing sections are processed, merge results into the existing `config.json` at the top level and show the summary (same format as **Confirm**, but listing only the added sections).

### Migration Flow (existing `.n1/n1.config.json`)

When an old `.n1/n1.config.json` is detected:

1. Compute project name (remote URL preferred, directory name fallback — must match `n1_home()` resolution):
   ```bash
   _raw=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null || true)
   [ -z "$_raw" ] && _raw=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
   PROJECT_NAME=$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
   ```

2. Prompt:
   ```
   Found existing N1 state at .n1/ in the project root.
   N1 2.0 stores state externally at ~/.n1/<project-name>/.

   Migrate to ~/.n1/<project-name>/?
   1 — Yes, migrate
   2 — No, keep current setup (state stays in project root)
   ```

3. **If 1 (Yes — migrate):**
   a. Create the external state directory:
      ```bash
      mkdir -p "$HOME/.n1/$PROJECT_NAME/memory"
      ```
   b. Read `.n1/n1.config.json`, update it:
      - Add `"version": "2.0.0"` field
      - Remove `worktree.enabled` if present (always on in v2.0.0)
   c. Write the updated config to `$HOME/.n1/$PROJECT_NAME/config.json`
   d. Move existing memory if present:
      ```bash
      if [ -d ".n1/memory" ] && [ "$(ls -A .n1/memory 2>/dev/null)" ]; then
          cp -r .n1/memory/* "$HOME/.n1/$PROJECT_NAME/memory/" 2>/dev/null || true
      fi
      ```
   e. Remove legacy git config if present:
      ```bash
      git config --unset n1.home 2>/dev/null || true
      ```
   f. Auto-detect `worktree.setup` (see **Worktree Setup Detection** in step 02) and add to config
   g. Add `${WT_ROOT}/` to gitignore (see **`.gitignore` configuration** in step 13)
   h. Clean up the old location (the copy in step d preserved the originals):
      ```bash
      rm -rf .n1/memory .n1/n1.config.json 2>/dev/null || true
      ```
      Then optionally remove the `.n1/` directory (ask user or leave it — the `.gitignore` entry was already addressed in step 3g above)
   i. Prune any `models.<agent>` entries in the migrated config that equal the agent's frontmatter default (removes stale hardcoded values from old configs). Run only when `HOST` is `claude-code`; skip entries whose value is an object (host-keyed).
      ```bash
      N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
      source "$N1_ROOT/lib/config.sh"; [ "$(n1_host)" = "claude-code" ] || exit 0
      CFG="$HOME/.n1/$PROJECT_NAME/config.json"
      for f in "$N1_ROOT"/agents/*.md; do a=$(basename "$f" .md)
        def=$(awk 'NR==1&&/^---$/{x=1;next} x&&/^---$/{exit} x&&/^model:/{sub(/^model:[ \t]*/,"");gsub(/\r/,"");print;exit}' "$f")
        cur=$(jq -r ".models[\"$a\"] // empty" "$CFG")
        [ "$(printf '%s' "$cur" | cut -c1)" = "{" ] && continue
        if [ -n "$cur" ] && [ "$cur" = "$def" ]; then
          jq "del(.models[\"$a\"])" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
          echo "pruned models.$a=$cur (equals frontmatter default)"
        fi
      done
      ```
   j. Report: "Migrated N1 state to `~/.n1/$PROJECT_NAME/`. Config, memory, and telemetry moved."
   k. Continue to **Analyze Repository** (skip the fresh setup sections that the migration already handled)

4. **If 2 (No — decline migration):**
   a. Rename config file in place:
      ```bash
      mv .n1/n1.config.json .n1/config.json
      ```
   b. Update the config content: add `"version": "2.0.0"` field
   c. Warn: "State will remain in the project root. Worktree isolation requires externalized state (absolute N1_HOME) — run n1-init again to migrate later."
   d. Continue to **Analyze Repository** (for CLAUDE.md enrichment and any new config fields)
