---
name: n1-story
description: "Story decomposition workflow. Decomposes features into design documents and subtask tickets: /n1:n1-story PROJ-100 or /n1:n1-story build user import feature --repos ~/dev/api,~/dev/web"
argument-hint: "<ticket-id or brain dump> [--repos path1,path2] [--step <name>]"
model: sonnet
effort: medium
---

# N1 Story Decomposition

## Overview

Decomposes a feature story into a design document and subtask tickets through multi-repo analysis, interactive discovery of unknowns, and tracker knowledge-base publishing. Each created subtask is independently executable via `/n1:n1-start`.

**Announce at start:** "I'm using the n1-story skill to decompose this feature."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run, before any config or memory access. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Would you like to run `/n1:n1-init` to set it up?" **Wait for response.** If yes — invoke `/n1:n1-init`, then resume. If no — **STOP.**

## Prerequisites

Read `$N1_HOME/config.json`:

- Check `story.enabled` (default `false`). If not enabled: "Story workflow is not enabled. Run `/n1:n1-init` to configure it, or manually set `story.enabled: true` in `$N1_HOME/config.json`." **STOP.**

## Input Parsing

The user provides one of:
- **Ticket ID** — matches the tracker prefix from config (e.g., `PROJ-100`)
- **Brain dump** — free-text description of the feature
- **File path** — a path to a feature brief or PRD

Optional flags:
- `--repos path1,path2` — additional repos to analyze (comma-separated)
- `--step <name>` — execute only the named step (step mode)

### Parse `--repos`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/story.sh"
repos_result=$(n1_parse_repos_arg "<raw-input>")
repos_exit=$?
```

If exit 0: extract `repos` (comma-separated paths) and `id` (remaining input). Validate each repo path exists:
```bash
IFS=',' read -ra REPO_PATHS <<< "$repos"
for rp in "${REPO_PATHS[@]}"; do
    expanded="${rp/#\~/$HOME}"
    if [ ! -d "$expanded/.git" ]; then
        echo "Warning: $rp is not a git repository, skipping"
    fi
done
```

The current working directory is always included as the first repo, even without `--repos`.

### Parse `--step`:

After stripping `--repos` from input, check for `--step`:

```bash
step_result=$(n1_parse_story_step_arg "<cleaned-input>")
step_exit=$?
```

Three outcomes:
- `exit 0` — step mode, parse `step_name` and `id_part`
- `exit 1` — full pipeline mode
- `exit 2` — invalid step name, emit error result and stop

### Detect input type:

After stripping all flags, use the remaining text:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/validation.sh"
n1_detect_input_type "<remaining-input>" "$N1_HOME/config.json"
```

Returns: `ticket`, `file`, or `braindump`.

## Step Mode

When `--step` is present and valid:

1. **Set `<ID>`** from parsed `id_part`.

2. **Read story-overview.md** — load `$N1_HOME/memory/<ID>/story-overview.md` for current state:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
   current_step=$(n1_read_frontmatter "$N1_HOME/memory/$ID/story-overview.md" "step")
   ```
   Exception: if step is `intake` and `story-overview.md` does not exist, this is a fresh start — skip the read.

3. **Verify dependencies:**
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/story.sh"
   deps=$(n1_story_step_dependencies "$step_name")
   if [ -n "$deps" ]; then
       n1_verify_dependencies "$N1_HOME/memory/$ID" $deps
   fi
   ```
   If verification fails, emit error and stop.

4. **Execute the step** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/<step_name>.md`.

5. **After step execution** — compute `next_step` from `pipeline.json` routing and emit:
   ```bash
   n1_emit_step_result "$step_name" "<outcome>" "<next_step>" "null"
   ```
   Then stop.

## Full Pipeline Mode

When `--step` is absent, run the complete pipeline sequentially:

1. **Intake** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/intake.md`
2. **Analysis** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/analysis.md`
3. **Discovery** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/discovery.md`
4. **Design** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/design.md`
5. **Review** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/review.md`
6. **Publish** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/publish.md`
7. **Decompose** — Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-story/steps/decompose.md`

Update `story-overview.md` progress checklist after each step completes. Update frontmatter `step` field to the current step name before each step starts:
```bash
n1_write_frontmatter "$N1_HOME/memory/$ID/story-overview.md" "step" "<step_name>"
```

## Telemetry

If `telemetry.enabled` is `true` in config, emit step markers using the same protocol as n1-start:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
N1_RUN_ID="${N1_RUN_ID:-$(date -u +n1-run-%Y%m%dT%H%M%SZ)}"
N1_VERSION=$(n1_config_val '.version' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json")
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "<step_name>" "start"
```

## Shared Context

These variables are resolved once and used across all steps:
- `$N1_HOME` — N1 state directory
- `$ID` — ticket ID or provisional slug
- `$MEMORY_DIR` — `$N1_HOME/memory/$ID`
- `$CONFIG_FILE` — `$N1_HOME/config.json`
- `$REPO_PATHS` — array of repo paths to analyze (always includes current repo)
- `$INPUT_TYPE` — one of: `ticket`, `file`, `braindump`
