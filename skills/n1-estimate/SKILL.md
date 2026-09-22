---
name: n1-estimate
description: "Estimate an existing ticket or task. Runs analysis pipeline then writes complexity tier and delivery time to tracker. Usage: /n1:n1-estimate TRID-510 or /n1:n1-estimate need CSV export for users"
argument-hint: "<ticket-id or task description>"
model: sonnet
effort: low
---

# N1 Estimation

## Overview

Estimate task complexity and delivery time for a ticket or task description. Runs the analysis pipeline (ticket read → codebase analysis → brainstorm) to build context, then classifies complexity and maps to a time estimate. Writes results to the tracker (if configured and enabled) or outputs to the user.

**Announce at start:** "I'm using the n1-estimate skill to estimate this task."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Estimate** — prerequisites, input parsing, model resolution, memory handling, pipeline, output
   Read `<N1_ROOT>/skills/n1-estimate/steps/01-estimate.md`
