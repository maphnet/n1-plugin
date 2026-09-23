---
name: n1-run
description: "Run a prompt with N1 project context — escape hatch from the full n1-pipeline."
---

# N1 Run

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
echo "N1_HOME=$N1_HOME"
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured. Run `/n1:n1-init` first." **STOP.**

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Execute

Apply the user's prompt directly. Choose the appropriate approach based on what the prompt asks for — do not force a specific persona or subagent.
