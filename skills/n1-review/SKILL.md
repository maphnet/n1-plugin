---
name: n1-review
description: "Code review with fix loop. No args = review current branch (fix cycle). With PR number = advisory review (report only)."
argument-hint: "[PR#]"
model: opus
effort: medium
---

# N1 Code Review

## Overview

Three-phase code review: **find → verify → report**. Specialized agents hunt for bugs ranked by priority (Critical/High/Medium/Low). A verification pass then rules out false positives before producing the final report.

**Announce at start:** "I'm using the n1-review skill to review the code."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
n1_resolve_model <agent-name>
```

Returns the config override if set, otherwise the agent's frontmatter default.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Analyze** — mode detection, priority levels, Review Loop phases 1-4, Advisory mode steps 1-3
   Read `<N1_ROOT>/skills/n1-review/steps/01-analyze.md`

2. **Report** — Phase 5 final report, Advisory mode step 4, memory update, integration
   Read `<N1_ROOT>/skills/n1-review/steps/02-report.md`
