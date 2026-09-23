<!-- Purpose: Assemble config.json, create directory structure, and configure .gitignore. -->

## Write Configuration and Structure

Create all files:

**Code-default keys (NOT written to config):** `testCoverage`, `review`, `ciChecks`, `planReview`, `escalation`, `memory` -- these have accessor functions in `lib/config.sh` with hardcoded defaults. Existing configs with these keys still work (values are read if present, never stripped).

**`$N1_HOME/config.json`** — assembled from sections above (where `$N1_HOME` was set during Fresh Setup or Migration):
```json
{
  "version": "2.0.0",
  "repoPath": "<absolute git toplevel, see below>",
  "worktree": {
    "mode": "worktree",
    "setup": "<detected or null>",
    "cleanup": "after-merge"
  },
  "tracker": { ... },
  "git": {
    "defaultBranch": "<detected>",
    "branchPattern": "<from tracker setup or feature/{slug}>",
    "prMode": "<from PR Mode Configuration selection>"
  },
  "ticketTagging": { ... },
  "observability": null,
  "estimation": {
    "enabled": false
  },
  "story": {
    "opusFromSize": "M"
  },
  "localTesting": {
    "enabled": true,
    "mode": "test"
  },
  "finishWork": {
    "enabled": false
  },
  "release": {
    "enabled": false
  },
  "telemetry": {
    "enabled": false
  },
  "rules": {
    "location": "private"
  },
  "kb": {
    "enabled": false
  },
  "relatedProjects": {
    "enabled": false,
    "maxSnapshotAge": "72h",
    "projects": []
  },
  "models": {}
}
```

**`repoPath`** is the absolute path of the repository's main checkout, used by `n1-queue` to launch subtask pipelines in the right repo:
```bash
REPO_PATH=$(git rev-parse --show-toplevel)
```
Store it as-is (WSL-native path on WSL). Do not store worktree paths — if the current directory is a worktree (`git rev-parse --git-common-dir` differs from `.git`), use `dirname "$(git rev-parse --git-common-dir)"` instead.

**`queue`** keys `tag`, `maxTickets`, `subtaskTimeoutMinutes` fall back to `defaults/queue.json`; set them in config.json only to override.

The `models` object is empty by default — agent model defaults come from agent frontmatter. Only store per-agent overrides here.

**Directory structure** (fresh setup only — migration handles this in the Migration Flow):
```bash
_raw=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null || true)
[ -z "$_raw" ] && _raw=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
PROJECT_NAME=$(printf '%s' "$_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
N1_HOME="$HOME/.n1/$PROJECT_NAME"
mkdir -p "$N1_HOME/memory"
git config --unset n1.home 2>/dev/null || true
```

Note: The `.n1/decisions/` directory is removed — it was unused in v1 and is not carried forward.

**`.gitignore` configuration** — detect existing coverage, then ask the user:

```bash
source ~/.n1/root/lib/preamble.sh
WT_ROOT=$(n1_worktree_root)   # host default from HOST ROUTING, or worktree.root from config
```

**Detection (run in order):**

1. Run `git config --global core.excludesFile` to get the global excludes file path.
   - If a path is returned AND the file exists, check whether it contains a line matching `${WT_ROOT}/` or `${WT_ROOT}`.
   - If `core.excludesFile` is unset, check Git's default location: `${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore`. If that file exists, check it for the same pattern.
2. If `${WT_ROOT}/` was not found in any global excludes file, check `.gitignore` in the project root for a line matching `${WT_ROOT}/` or `${WT_ROOT}`.

**If already gitignored:**
- Found globally → tell the user: "`${WT_ROOT}/` is already gitignored globally via `<path>`." Move on.
- Found in project `.gitignore` → tell the user: "`${WT_ROOT}/` is already gitignored in this project's `.gitignore`." Move on.

**If NOT gitignored anywhere**, ask:

```
${WT_ROOT}/ directory is not gitignored. Where would you like to add it?
1 — Globally (user-scoped gitignore, applies to all repos)
2 — Project-level (.gitignore in this repo)
```

**If 1 (Global):**

1. Run `git config --global core.excludesFile`.
2. **If set** → append the entry to that file (with duplicate check):
   ```bash
   # only if ${WT_ROOT} entry not already present in the file:
   echo "" >> "<excludesFile>"
   echo "# N1 worktree directories" >> "<excludesFile>"
   echo "${WT_ROOT}/" >> "<excludesFile>"
   ```
   Tell the user: "Added `${WT_ROOT}/` to global gitignore (`<path>`)."
   Then check project `.gitignore` for a stale `${WT_ROOT}` entry (see **Project-level cleanup after global add** below).
3. **If NOT set** → check for Git's default global excludes file before offering to create one:
   ```bash
   XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
   DEFAULT_EXCLUDES="$XDG/git/ignore"
   ```
   - **If `$DEFAULT_EXCLUDES` exists** → Git is already using it as the implicit global excludes file. Check whether it contains `${WT_ROOT}`. If not, append the entry there:
     ```bash
     echo "" >> "$DEFAULT_EXCLUDES"
     echo "# N1 worktree directories" >> "$DEFAULT_EXCLUDES"
     echo "${WT_ROOT}/" >> "$DEFAULT_EXCLUDES"
     ```
     Tell the user: "Added `${WT_ROOT}/` to Git's default global excludes (`$DEFAULT_EXCLUDES`). No `core.excludesFile` change needed."
     Then check project `.gitignore` for a stale `${WT_ROOT}` entry (see **Project-level cleanup after global add** below).
   - **If `$DEFAULT_EXCLUDES` does not exist** → sub-prompt:
     ```
     No global gitignore is configured (core.excludesFile is unset and $XDG_CONFIG_HOME/git/ignore does not exist).
     Want me to create ~/.config/git/ignore (Git's default location) for global excludes?
     1 — Yes
     2 — No (fall back to project-level)
     ```
     - **1 (Yes):**
       ```bash
       mkdir -p "$XDG/git"
       echo "# N1 worktree directories" >> "$XDG/git/ignore"
       echo "${WT_ROOT}/" >> "$XDG/git/ignore"
       ```
       Tell the user: "Created `$XDG/git/ignore` and added `${WT_ROOT}/`. Git uses this location by default — no `core.excludesFile` needed."
       Then check project `.gitignore` for a stale `${WT_ROOT}` entry (see **Project-level cleanup after global add** below).
     - **2 (No):** Fall through to project-level append below.

**If 2 (Project-level) from the main prompt**, or fell through from the global sub-prompt:

```bash
# only if ${WT_ROOT} entry not already present in .gitignore:
if ! grep -qF "${WT_ROOT}" .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# N1 worktree directories" >> .gitignore
    echo "${WT_ROOT}/" >> .gitignore
fi
```
Tell the user: "Added `${WT_ROOT}/` to this project's `.gitignore`."

**Project-level cleanup after global add:**

After successfully adding `${WT_ROOT}/` to the global excludes file, check if the project `.gitignore` also contains a `${WT_ROOT}/` or `${WT_ROOT}` entry. If found, ask:

```
${WT_ROOT}/ is now gitignored globally. The project .gitignore also has this entry.
1 — Remove it from .gitignore (global covers it)
2 — Keep both (redundant, but harmless)
```

**If 1 (Remove):** remove the `${WT_ROOT}/` line and its comment line (`# N1 worktree directories`) if present on the preceding line. Tell the user: "Removed redundant `${WT_ROOT}/` entry from project `.gitignore`."

**If 2 (Keep):** move on.

**Migration cleanup — old `.n1/` entry:**

During migration only (step 3g), after adding `${WT_ROOT}/`, check if the project `.gitignore` contains an `.n1/` or `.n1` entry. If found, check whether the `.n1/` directory still exists and contains files:

```bash
if [ -d ".n1" ] && [ "$(ls -A .n1 2>/dev/null)" ]; then
    # Directory still has files — keep it ignored
    HAS_LEFTOVER=true
else
    HAS_LEFTOVER=false
fi
```

**If `.n1/` has leftover files** (`HAS_LEFTOVER=true`): tell the user: "`.n1/` still contains files — keeping gitignore entry to prevent committing leftover state. Remove `.n1/` manually when ready, then the entry can be cleaned up." Move on.

**If `.n1/` is empty or does not exist**, ask:

```
The old .n1/ entry is still in this project's .gitignore.
Since N1 state is now externalized to ~/.n1/<project>/, this entry is no longer needed.
1 — Remove it
2 — Keep it (harmless, but unnecessary)
```

**If 1 (Remove):** remove the `.n1/` line and its comment line (`# N1 plugin state`) if present on the preceding line. Tell the user: "Removed old `.n1/` entry from `.gitignore`."

**If 2 (Keep):** tell the user: "Kept `.n1/` entry — it does no harm." Move on.
