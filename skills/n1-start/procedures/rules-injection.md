# Procedure: Rules Injection

Prepares a rules block to inject into an agent spawn prompt. The block is empty when no matching rules exist.

## Rules Injection

**Parameters:** `{agent_name}` (e.g. `"developer"`, `"solution-architect"`), `{changed_files_source}` (optional signal key to read changed files from, e.g. `"diff_surface"` from `implementation.md`)

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    CHANGED_FILES=""
    # If changed_files_source is provided, read the signal
    # CHANGED_FILES=$(n1_read_signal "$N1_HOME/memory/$ID/{source_file}" "{changed_files_source}")
    MATCHING_RULES=$(n1_rules_for_agent "{agent_name}" "$CHANGED_FILES" "$RULES_DIR")
    if [ -n "$MATCHING_RULES" ]; then
        RULES_BLOCK=$(n1_rules_render $MATCHING_RULES)
    fi
fi
```

When `$RULES_BLOCK` is non-empty, append it to the agent's spawn prompt.
