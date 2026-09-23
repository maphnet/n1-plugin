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
source ~/.n1/root/lib/preamble.sh
source "$N1_ROOT/lib/rules.sh"

N1_HOME=$(n1_home)
RULES_DIR=$(n1_rules_dir)
```

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Manage** — command routing, list command, add command (steps 1-9)
   Read `<N1_ROOT>/skills/n1-rules/steps/01-manage.md`

2. **Deny Hooks** — deny hook generation (add step 9), check command, check --fix command
   Read `<N1_ROOT>/skills/n1-rules/steps/02-deny-hooks.md`
