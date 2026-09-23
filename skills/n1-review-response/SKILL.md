---
name: n1-review-response
description: "Respond to PR review comments. Verifies each comment against the codebase, fixes valid issues via developer agent, and posts inline rejection replies for invalid ones."
argument-hint: "[PR#]"
model: sonnet
effort: medium
---

# N1 Review Response

## Overview

Three-phase on-demand skill: **fetch → verify → act**. Fetches all open review comments on a PR, verifies each claim against codebase reality, presents verdicts for user confirmation, then fixes valid issues via the developer agent and posts inline rejection replies for invalid ones.

**Announce at start:** "I'm using the n1-review-response skill to respond to PR review comments."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

Config: `$N1_HOME/config.json`. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source ~/.n1/preamble.sh
n1_resolve_agent <agent-name> [step-context]
```

Split the tab-separated model/effort result and pass both values to the host spawn. This
workflow does not authorize an Astra context; `n1_resolve_model` is compatibility-only.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Triage** — prerequisites, resolve PR context, fetch comments, classify authors, verify claims
   Read `<N1_ROOT>/skills/n1-review-response/steps/01-triage.md`

2. **Resolve** — present verdicts, act on confirmed verdicts, report and memory update
   Read `<N1_ROOT>/skills/n1-review-response/steps/02-resolve.md`
