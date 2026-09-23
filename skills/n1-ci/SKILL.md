---
name: n1-ci
description: "Monitor CI checks after PR creation. Auto-fixes failures via developer agent, escalates to user after max attempts. Usage: /n1:n1-ci or /n1:n1-ci #123"
argument-hint: "[PR#]"
model: sonnet
effort: low
---

# N1 CI Watch & Fix

## Overview

Monitor CI checks on a PR, classify failures, and delegate fixes to the developer agent. User involvement only when max fix attempts exhausted or unknown check below confidence threshold.

**Announce at start:** "I'm using the n1-ci skill to monitor CI checks."

## N1_HOME Resolution

```bash
source ~/.n1/root/lib/preamble.sh
```

If empty — N1 not configured; warn the user. Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source ~/.n1/root/lib/preamble.sh
n1_resolve_agent <agent-name> [step-context]
```

Split the tab-separated model/effort result and pass both values to the host spawn. CI fix
dispatches do not supply an Astra context; `n1_resolve_model` is compatibility-only.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Monitor** — prerequisites, resolve PR, read CI config, poll for CI checks, evaluate results
   Read `<N1_ROOT>/skills/n1-ci/steps/01-monitor.md`

2. **Fix** — classify failures, fix cycle, report and memory update
   Read `<N1_ROOT>/skills/n1-ci/steps/02-fix.md`
