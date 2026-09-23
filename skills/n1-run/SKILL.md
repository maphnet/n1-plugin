---
name: n1-run
description: "Load N1 project config and run a prompt with full project context — escape hatch from the full n1-pipeline."
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

## Load Config

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
cat "$N1_HOME/config.json" 2>/dev/null || echo "{}"
```

## Execute

You now have N1 project context loaded. Apply the user's prompt directly — you have full tool access including MCP. Choose the appropriate approach (direct execution, persona dispatch, MCP queries, research, analysis) based on what the prompt actually asks for.

Do not force a developer subagent or any specific persona unless the task is clearly an implementation task that benefits from one.
