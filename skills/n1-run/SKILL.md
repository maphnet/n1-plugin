---
name: n1-run
description: "Load N1 project config and run a coding task directly — escape hatch from the full n1-pipeline."
---

# N1 Run

**Announce at start:** "I'm using the n1-run skill to run a coding task."

## N1_HOME Resolution

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
echo "N1_HOME=$N1_HOME"
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured. Run `/n1:n1-init` first." **STOP.**

## Load Context

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/rules.sh"
N1_HOME=$(n1_home)
RULES_DIR=$(n1_rules_dir)
RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    MATCHING_RULES=$(n1_rules_for_agent "developer" "" "$RULES_DIR")
    [ -n "$MATCHING_RULES" ] && RULES_BLOCK=$(n1_rules_render $MATCHING_RULES)
fi
RESOLVE=$(n1_resolve_agent "developer" 2>/dev/null || echo "sonnet	normal")
AGENT_MODEL=$(printf '%s' "$RESOLVE" | cut -f1)
AGENT_EFFORT=$(printf '%s' "$RESOLVE" | cut -f2)
echo "N1_HOME=$N1_HOME"
echo "AGENT_MODEL=$AGENT_MODEL"
echo "AGENT_EFFORT=$AGENT_EFFORT"
[ -n "$RULES_BLOCK" ] && printf '%s\n' "$RULES_BLOCK"
```

## Dispatch

Dispatch persona `developer` with the following brief:

```
N1 project context:
- N1_HOME: <N1_HOME from above>
- Model: <AGENT_MODEL> / Effort: <AGENT_EFFORT>

<RULES_BLOCK — include verbatim if non-empty, omit section entirely if empty>

Task:
<user's prompt verbatim — do not transform, summarize, or interpret>
```

Return the developer persona's output directly to the user.

> **Note:** The developer persona has access to `Read`, `Edit`, `Write`, `Bash`, `Grep`, and `Glob`.
> It does not have access to tracker or observability MCP tools. If your task requires those, use `/n1:n1-start` instead.
