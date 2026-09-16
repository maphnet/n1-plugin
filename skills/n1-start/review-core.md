# Review Core — Shared Reviewer Selection

Used by `steps/review.md` and `n1-review`. Caller must define `<BASE_BRANCH>`.

## Diff Surface Classification

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
BASE=$(git merge-base "<BASE_BRANCH>" HEAD)
CHANGED=$(git diff --name-only "$BASE" HEAD)
FILE_COUNT=$(echo "$CHANGED" | wc -l)
if [ "$FILE_COUNT" -gt 200 ]; then
  CHANGED="$(echo "$CHANGED" | head -n 200)
[truncated: showing first 200 of $FILE_COUNT files]"
fi
source "$N1_ROOT/lib/classify.sh"
DOC_CONFIG_ONLY=$(n1_classify_doc_config_only "$CHANGED")
SECURITY_HINT=$(n1_classify_security_hint_any "$CHANGED")
echo "DOC_CONFIG_ONLY=${DOC_CONFIG_ONLY}"
echo "SECURITY_HINT=${SECURITY_HINT}"
```

- **DOC_CONFIG_ONLY** (pre-computed) — `$DOC_CONFIG_ONLY`. When `true`, every changed file is docs or config.
- **SECURITY_RELEVANT** — use `$SECURITY_HINT` as starting signal; inspect diff content for final verdict. True iff any path or diff touches: auth, crypto, input validation, secrets, network/HTTP, (de)serialization, file/path handling, SQL/query, shell/command execution. **Bias toward true when uncertain.**

Reviewer selection: `code-reviewer` always runs. `security-reviewer` runs iff `SECURITY_RELEVANT`. Record each skip in `review.md` + Decision Ledger row.

## Gate Rule Injection

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
CR_RULES_BLOCK=""
SEC_RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    CHANGED=$(git diff --name-only "$BASE" HEAD 2>/dev/null)
    CR_GATE_FILES=$(n1_rules_for_agent "code-reviewer" "$CHANGED" "$RULES_DIR" | while IFS= read -r rf; do [ -z "$rf" ] && continue; [ "$(n1_rule_field "$rf" "enforcement")" = "gate" ] && printf '%s ' "$rf"; done); [ -n "$CR_GATE_FILES" ] && CR_RULES_BLOCK=$(n1_rules_render $CR_GATE_FILES)
    SEC_GATE_FILES=$(n1_rules_for_agent "security-reviewer" "$CHANGED" "$RULES_DIR" | while IFS= read -r rf; do [ -z "$rf" ] && continue; [ "$(n1_rule_field "$rf" "enforcement")" = "gate" ] && [ "$(n1_rule_field "$rf" "topic")" = "security" ] && printf '%s ' "$rf"; done); [ -n "$SEC_GATE_FILES" ] && SEC_RULES_BLOCK=$(n1_rules_render $SEC_GATE_FILES)
fi
```

`$CR_RULES_BLOCK` non-empty: append to code-reviewer prompt. `[RULE-N]` violations → review FAIL. `$SEC_RULES_BLOCK` non-empty: append to security-reviewer prompt; violations fold into `[SEC-N]` findings. No gate rules: record `"Rule compliance: no gate rules configured."` in review.md.
