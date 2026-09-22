---
name: n1-story
description: "Create a story with subtask tickets from conversation context: /n1:n1-story [description]"
argument-hint: "[description or brain dump text]"
model: sonnet
effort: medium
---

# N1 Story from Context

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context (a question tool on Claude Code, a plain numbered-options message on Codex). "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Create a story with subtask tickets from the current conversation context and/or a provided description. All tickets are created as backlog items — no status transitions, no branch creation.

**Announce at start:** "I'm using the n1-story skill to create a story with subtasks."

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Collect** — context capture, sanity check, tracker gate, analysis, discovery, design
   Read `<N1_ROOT>/skills/n1-story/steps/01-collect.md`

2. **Compose** — approval gate, create story, create subtasks, done
   Read `<N1_ROOT>/skills/n1-story/steps/02-compose.md`
