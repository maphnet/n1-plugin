---
name: n1-telemetry
description: "Analyze optimization decision telemetry. Correlates signal-driven decisions (skip/downgrade/escalate) with quality outcomes (review pass rate, fix cycles) and produces threshold calibration recommendations."
argument-hint: "[--project <path>]"
model: sonnet
effort: medium
---

# N1 Telemetry Analysis

Aggregate decision-to-outcome correlations across pipeline runs and produce threshold calibration recommendations.

**Announce at start:** "I'm using the n1-telemetry skill to analyze optimization decisions."

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty, tell the user N1 is not configured and stop.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Collect** — data collection, decision summary, decision-outcome correlation, threshold recommendations
   Read `<N1_ROOT>/skills/n1-telemetry/steps/01-collect.md`

2. **Analyze** — token usage, compaction events, question quality, brainstorm context analysis, local testing effectiveness, output format
   Read `<N1_ROOT>/skills/n1-telemetry/steps/02-analyze.md`
