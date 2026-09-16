---
name: n1-pr
description: "Finalize the branch: update docs, push, create PR based on config, and update tracker."
model: sonnet
effort: low
---

# N1 Pull Request Creation

## Overview

Create a PR from the current feature branch. Spawns tech-writer for PR content, then handles push, PR creation via `gh`, and tracker update.

**Announce at start:** "I'm using the n1-pr skill to finalize the branch."

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If empty — N1 not configured; warn the user. Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
n1_resolve_agent <agent-name> [step-context]
```

Split the tab-separated model/effort result and pass both values to the host spawn. PR
preparation does not supply an Astra context; `n1_resolve_model` is compatibility-only.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Prepare** — prerequisites, PR mode resolution, collect information, documentation update, generate PR content
   Read `<N1_ROOT>/skills/n1-pr/steps/01-prepare.md`

2. **Push & Create** — push and create PR, update tracker, update memory, report, post-PR follow-ups
   Read `<N1_ROOT>/skills/n1-pr/steps/02-push-create.md`
