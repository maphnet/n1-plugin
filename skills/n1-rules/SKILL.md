---
name: n1-rules
description: "List, add, and validate N1 project rules. Rules are authored, checkable project conventions that drive review gates and deny hooks."
model: sonnet
effort: low
---

# N1 Rules

## Overview

Manage project rules — authored, checkable conventions that drive review gates (`gate`) and PreToolUse deny hooks (`deny`). Rules live in `.rule.md` files with YAML frontmatter.

**Announce at start:** "I'm using the n1-rules skill to manage project rules."

**UX rules:**
- All choice questions MUST offer numbered options so the user can answer with just a number.

## Preamble

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/rules.sh"

N1_HOME=$(n1_home)
RULES_DIR=$(n1_rules_dir)
```

Parse the user's command from the invocation arguments. If no command given, show usage:
```
Usage: /n1:n1-rules <command>

Commands:
  list          Show all project rules
  add           Create a new rule interactively
  check         Validate all rules
  check --fix   Validate and regenerate deny hook
```

---

## Command: `list`

If `$RULES_DIR` is empty or the directory does not exist:
```
No rules configured. Run /n1:n1-init to set up rules, or use /n1:n1-rules add to create one manually.
```
**STOP.**

Otherwise, iterate all rule files and display:

```
Project Rules ($RULES_DIR)

| Rule | Topic | Applies To | Enforcement | Paths |
|------|-------|------------|-------------|-------|
```

For each file from `n1_rules_list "$RULES_DIR"`:
- Name: basename without `.rule.md`
- Read fields via `n1_rule_field`

After the table, show total count. If count > 10:
```
⚠ {N} rules — research shows >10 blocking rules risk degrading task success. Consider consolidating.
```

---

## Command: `add`

Interactive rule authoring. Steps:

**1. Description:**
```
Rule description (one line — what this rule requires):
```

**2. Name:**
Derive a kebab-case slug from the description. Confirm:
```
Rule file: {slug}.rule.md
1 — Use this name
2 — Enter a different name
```

**3. Topic:**
```
Topic:
1 — code-style
2 — testing
3 — security
4 — architecture
5 — process
6 — writing
7 — ops
```

**4. Applies to:**
```
Which agents should check this rule?
1 — developer, code-reviewer (code changes — most common)
2 — All agents (*)
3 — Custom (enter comma-separated agent names)
```

If option 2 selected, warn: "A rule that applies to every persona is usually a rule that belongs in CLAUDE.md instead. Continue? 1 — Yes / 2 — No"

Valid agent names: `product-analyst`, `solution-architect`, `planner`, `implementer`, `developer`, `code-reviewer`, `security-reviewer`, `qa-engineer`, `tech-writer`, `local-test-planner`

**5. Enforcement — push toward deny:**
```
Can this rule be checked mechanically from file paths or command strings?
Examples: "don't edit vendor/" (path check), "no force push" (command check)

1 — Yes → deny (blocks the action deterministically)
2 — No, it requires judgment → gate (reviewer checks, violation fails review)
```

**If deny (option 1):**
```
What should be denied?
1 — File paths (block Edit/Write to matching paths)
2 — Commands (block Bash commands matching a pattern)
3 — Both
```

For paths: "Enter path glob patterns, comma-separated (e.g., `vendor/**,dist/**`):"
For commands: "Enter command patterns, comma-separated (e.g., `git push --force,git commit * main`):"

**6. Path scoping (optional):**
```
Limit this rule to specific file paths? (leave empty for all files)
Enter glob patterns, comma-separated (e.g., src/api/**,lib/**):
```

**7. Rule body:**
```
Write the rule text — the prose that gets injected into agent prompts.
This should clearly state what TO do (not what NOT to do).
```

**For `gate` rules:** Check positive phrasing. If the body starts with "Do not", "Never", "Don't", "Must not", or "Avoid":
```
⚠ Gate rules should be phrased positively — state what TO do, not what NOT to do.
LLM reviewers are systematically weak at detecting negation violations.

Example: Instead of "Never skip validation", write "Validate every request body through lib/validate.ts"

1 — Rephrase
2 — Keep as-is (not recommended)
```

**8. Write the rule file:**

Create the rules directory if it doesn't exist: `mkdir -p "$RULES_DIR"`

Write `$RULES_DIR/{name}.rule.md`:
```yaml
---
description: {description}
topic: {topic}
applies_to: [{agents}]
enforcement: {deny|gate}
paths: [{paths}]       # omit if empty
deny:                   # only for deny rules
  paths: [{deny_paths}]     # omit if not applicable
  commands: [{deny_commands}] # omit if not applicable
---

{body}
```

If `rules` is not set in config, write `"rules": { "enabled": true }` to config.

**9. If enforcement is `deny`:**

Generate and register the deny hook:
```bash
HOOK_DIR="$N1_HOME/hooks"
mkdir -p "$HOOK_DIR"
HOOK_PATH="$HOOK_DIR/rules-deny.sh"

n1_generate_deny_hook "$RULES_DIR" "$HOOK_PATH"
n1_deny_hook_register "$HOOK_PATH"
```

Tell the user: "Deny hook generated and registered. Matching tool calls will be blocked."

**10. Summary:**
```
Rule created: {name}.rule.md
  Description: {description}
  Topic: {topic}
  Applies to: {agents}
  Enforcement: {enforcement}
  Location: {RULES_DIR}/{name}.rule.md
```

---

## Command: `check`

Validate all rules. Report issues as warnings or errors.

```bash
RULES_DIR=$(n1_rules_dir)
```

If no rules directory or empty: "No rules to check." **STOP.**

For each rule file:

**Required fields:** `description`, `topic`, `applies_to`, `enforcement`
- Missing field → ERROR: "Rule `{name}` missing required field: `{field}`"

**Topic validation:** must be one of: `code-style`, `testing`, `security`, `architecture`, `process`, `writing`, `ops`
- Invalid → ERROR: "Rule `{name}` has invalid topic: `{value}`"

**Enforcement validation:** must be `deny` or `gate`
- Invalid → ERROR: "Rule `{name}` has invalid enforcement: `{value}`"

**`applies_to: *` warning:**
- WARN: "Rule `{name}` applies to every persona — consider whether it belongs in CLAUDE.md instead."

**Gate rule positive phrasing:**
- If body starts with "Do not"/"Never"/"Don't"/"Must not"/"Avoid" → WARN: "Rule `{name}` uses negative phrasing. Gate rules should state what TO do — LLM reviewers are weak on negation."

**Deny rule predicate check:**
- If enforcement is `deny` but neither `deny.paths` nor `deny.commands` exists → ERROR: "Rule `{name}` is `deny` but has no deny predicates (paths or commands). Add deny.paths or deny.commands, or change to gate."

**Count warning:**
- If total rules > 10 → WARN: "⚠ {N} rules — research shows >10 blocking rules risk degrading task success. Consider consolidating."

**Report:**
```
Checked {N} rules: {errors} errors, {warnings} warnings.
```

---

## Command: `check --fix`

Run all checks from the `check` command above, then:

**Deny hook regeneration:**

```bash
HAS_DENY=false
while IFS= read -r rf; do
    [ -z "$rf" ] && continue
    enf=$(n1_rule_field "$rf" "enforcement")
    [ "$enf" = "deny" ] && HAS_DENY=true && break
done < <(n1_rules_list "$RULES_DIR")
```

**If `HAS_DENY` is true:**

1. Determine hook output path:
   ```bash
   HOOK_DIR="$N1_HOME/hooks"
   mkdir -p "$HOOK_DIR"
   HOOK_PATH="$HOOK_DIR/rules-deny.sh"
   ```

2. Generate: `n1_generate_deny_hook "$RULES_DIR" "$HOOK_PATH"`

3. Register: `n1_deny_hook_register "$HOOK_PATH"`

4. Report: "Deny hook generated at `$HOOK_PATH` and registered."

**If `HAS_DENY` is false and a hook was previously registered:**

1. Determine `$HOOK_PATH` same as above
2. Deregister: `n1_deny_hook_deregister "$HOOK_PATH"`
3. Remove the generated hook file: `rm -f "$HOOK_PATH"`
4. Report: "No deny rules found. Deny hook removed."
