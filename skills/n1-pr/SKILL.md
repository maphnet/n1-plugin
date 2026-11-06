---
name: n1-pr
description: "Finalize the branch: update docs, push, create PR based on config, and update tracker."
effort: low
---

# N1 Pull Request Creation

## Overview

Create a PR from the current feature branch. Spawns tech-writer for PR content, then handles push, PR creation via `gh`, and tracker update.

**Announce at start:** "I'm using the n1-pr skill to finalize the branch."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] && echo "N1_HOME=$N1_HOME" || echo N1_NOT_CONFIGURED
```

If the output shows `N1_NOT_CONFIGURED` — N1 not configured; warn the user. Config: read keys via `n1_*_val` helpers; never cat config.json. Memory: `$N1_HOME/memory/$ID/`.

## Model Resolution

```bash
source ~/.n1/preamble.sh
n1_resolve_agent <agent-name> [step-context]
```

Split the tab-separated model/effort result and pass both values to the host spawn.
`n1_resolve_model` is compatibility-only.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Prepare** — pre-push Codex review (one pass), prerequisites, PR mode resolution, collect information, documentation update, generate PR content
   Read `<N1_ROOT>/skills/n1-pr/steps/01-prepare.md`

2. **Push & Create** — push and create PR, update tracker, update memory, post-PR follow-ups
   Read `<N1_ROOT>/skills/n1-pr/steps/02-push-create.md`

3. **Codex Comment & Report** — always runs after step 2: pins the reviewed head, posts the pre-push Codex triage once, discloses unreviewed soft fixes, then prints the final PR report + CHECKPOINT. The Codex review itself runs in step 1 before the push (it self-skips on opt-out or missing CLI/auth). n1-pr is not done until this step prints its Report.
   Read `<N1_ROOT>/skills/n1-pr/steps/03-codex-review.md`
