---
name: n1-story
description: "Use when creating backlog tickets from an initiative or conversation whose scope may require a Story and child tickets."
argument-hint: "[description or brain dump text]"
model: sonnet
effort: medium
---

# N1 Story from Context

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context. "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Choose ticket structure from the confirmed scope: one atomic change in one repository becomes a standalone Task; meaningful decomposition or required cross-repository work becomes a Story with child tickets. All tickets are created as backlog items — no status transitions, no branch creation.

**Announce at start:** "I'm using the n1-story skill to determine the scope and create backlog tickets."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Collect** — context capture, sanity check, tracker gate, analysis, discovery, design (existing keys may be adopted as sub-tasks)
   Read `<N1_ROOT>/skills/n1-story/steps/01-collect.md`

2. **Compose** — approval gate, create story, create subtasks, adopt existing tickets, done
   Read `<N1_ROOT>/skills/n1-story/steps/02-compose.md`
