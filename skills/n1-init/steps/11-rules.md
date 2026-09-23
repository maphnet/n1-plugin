<!-- Purpose: Generate starter project rules and optionally migrate CLAUDE.md behavioral conventions. -->

## Rules Configuration

Ask whether N1 should generate project rules — authored, checkable conventions that drive review gates and deny hooks. **Default is Yes** for new setups, presented after all other config is written.

```
N1 can generate project rules from what it detects about your project.
Rules are checkable conventions — violations block reviews or deny tool calls.
1 — Yes, generate starter rules (recommended)
2 — No, skip rules for now
```

**If 2 (No) or skip:** Write `"rules": { "enabled": true }` to config and move on. No rules directory created.

**If 1 (Yes):**

1. Set `RULES_DIR="$N1_HOME/rules"`. Write `"rules": { "enabled": true }` to config.

2. Create the rules directory: `mkdir -p "$RULES_DIR"`

2b. **Seed default rules.** Scan `<N1_ROOT>/defaults/rules/` for `.rule.md` files. For each file, check whether a rule with the same basename already exists in `$RULES_DIR/`. If it does, skip silently. If it does not, present it using the same Accept/Edit/Skip UX as detection-based rules:

   ```
   Default rule: <name>
     Description: <description field>
     Topic: <topic field>
     Applies to: <applies_to field>
     Enforcement: <enforcement field>
     Body:
       <rule body text>

   1 — Accept
   2 — Edit (modify before saving)
   3 — Skip
   ```

   - **1 (Accept):** Copy the file to `$RULES_DIR/<name>.rule.md`
   - **2 (Edit):** Let the user modify the description, body, and enforcement, then write the edited version
   - **3 (Skip):** Do not create this rule

   Default rules are presented before detection-based rules so universal conventions appear first.

3. Generate starter rules from existing detection results. For each detected characteristic, propose a rule with enforcement recommendation. Present **one at a time** for approval:

   **From lockfile/package manager detection:**
   - Propose a `deny` rule if a lockfile exists: "no direct edits to `<lockfile>`" with `deny.paths: ["<lockfile>"]`
     - `topic: ops`, `applies_to: [developer, implementer]`, `enforcement: deny`

   **From analysis cache snapshot (when available):**
   - If `$N1_HOME/cache/project-snapshot.md` exists, read its conventions section and propose `gate` rules for any convention that is checkable

   For each proposed rule, show:
   ```
   Proposed rule: <name>
     Description: <one-line>
     Topic: <topic>
     Applies to: <agents>
     Enforcement: <deny|gate>
     Body:
       <rule text>

   1 — Accept
   2 — Edit (modify before saving)
   3 — Skip
   ```

   - **1 (Accept):** Write the rule file to `$RULES_DIR/<name>.rule.md`
   - **2 (Edit):** Let the user modify the description, body, and enforcement, then write
   - **3 (Skip):** Do not create this rule

4. After all proposals: show count of accepted rules. If > 10, warn about cost-of-compliance.

5. If any accepted rules have `enforcement: deny`:
   ```bash
   source ~/.n1/preamble.sh
   source "$N1_ROOT/lib/rules.sh"
   HOOK_DIR="$N1_HOME/hooks"
   mkdir -p "$HOOK_DIR"
   HOOK_PATH="$HOOK_DIR/rules-deny.sh"
   n1_generate_deny_hook "$RULES_DIR" "$HOOK_PATH"
   n1_deny_hook_register "$HOOK_PATH"
   ```
   Tell the user: "Deny hook installed — matching tool calls will be blocked."

### CLAUDE.md Convention Migration (conditional)

**Only show this section when at least one rule was created in the Rules Configuration step above.**

Scan CLAUDE.md for behavioral convention blocks — lines that prescribe behavior (imperative mood: "always", "never", "must", "use X for Y") rather than state facts. For each identified block:

```
Found behavioral convention in CLAUDE.md:

  > <quoted block>

This could become a rule. Extract it?
1 — Yes, extract as gate rule
2 — Yes, extract as deny rule (if mechanically checkable)
3 — No, leave in CLAUDE.md
```

- **1 or 2:** Create a rule file, ask for `applies_to`, then ask:
  ```
  Remove this convention from CLAUDE.md now that it's a rule?
  1 — Yes, remove from CLAUDE.md
  2 — No, keep in both places
  ```
- **3:** Leave in place

**Do NOT add any "Project Rules" section to CLAUDE.md.** Do NOT remove factual content — only behavioral prescriptions the user explicitly chose to remove.

### On reconfiguration (n1-init re-run):

If `rules` already exists in the current config:

```
Current rules:
  count → <N> rules

1 — Keep current
2 — Re-generate starter rules (adds to existing, does not delete)
```

- **1** → leave unchanged.
- **2** → re-run default rule seeding (step 2b) and detection-based rule generation (step 3). Both skip rules that already exist by name in `$RULES_DIR/`.

**Repo→private migration:** If rules exist at `<root>/.n1/rules/` (legacy repo mode), detect and offer:
```
Found rules in <root>/.n1/rules/ (legacy repo mode).
Rules now always live in $N1_HOME/rules/.
1 — Move rules to $N1_HOME/rules/
2 — Leave as-is (rules will not be discovered)
```
If 1: move all `.rule.md` files, regenerate deny hook at new location, deregister old hook path.

If `rules` is absent from the current config, run the fresh-setup flow above. Run **Analyze Repository** first if it has not already been run this session (rules starter generation needs detection results).
