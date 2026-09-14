<!-- Purpose: Command routing, list command, add command steps 1-9. -->

## Command Routing

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

**9. If enforcement is `deny`:** proceed to step file 02-deny-hooks.md for deny hook generation and registration.
