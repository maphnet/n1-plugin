<!-- Purpose: Deny hook generation (add command step 9), check command, check --fix command. -->

## Add Command: Step 9 — Deny Hook Generation

When enforcement is `deny`, generate and register the deny hook:

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
