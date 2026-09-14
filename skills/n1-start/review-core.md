# Review Core — Shared Reviewer Selection

Used by `steps/review.md` and `n1-review`. Caller must define `<BASE_BRANCH>`.

## Diff Surface Classification

```bash
BASE=$(git merge-base "<BASE_BRANCH>" HEAD)
CHANGED=$(git diff --name-only "$BASE" HEAD)
```

- **DOC_CONFIG_ONLY** — true iff every changed path matches only `*.md`, `*.txt`, `*.yml`/`*.yaml`, `.gitignore`, `LICENSE`, `CHANGELOG*`.
- **SECURITY_RELEVANT** — true iff any path or diff touches: auth, crypto, input validation, secrets, network/HTTP, (de)serialization, file/path handling, SQL/query, shell/command execution. **Bias toward true when uncertain.**

Reviewer selection: `code-reviewer` always runs. `security-reviewer` runs iff `SECURITY_RELEVANT`. Record each skip in `review.md` + Decision Ledger row.

## Gate Rule Injection

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
CR_RULES_BLOCK=""
SEC_RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    CHANGED=$(git diff --name-only "$BASE" HEAD 2>/dev/null)
    CR_GATE_FILES=""
    while IFS= read -r rf; do
        [ -z "$rf" ] && continue
        enf=$(n1_rule_field "$rf" "enforcement")
        [ "$enf" = "gate" ] && CR_GATE_FILES="${CR_GATE_FILES} ${rf}"
    done < <(n1_rules_for_agent "code-reviewer" "$CHANGED" "$RULES_DIR")
    if [ -n "$CR_GATE_FILES" ]; then CR_RULES_BLOCK=$(n1_rules_render $CR_GATE_FILES); fi
    SEC_GATE_FILES=""
    while IFS= read -r rf; do
        [ -z "$rf" ] && continue
        enf=$(n1_rule_field "$rf" "enforcement")
        topic=$(n1_rule_field "$rf" "topic")
        [ "$enf" = "gate" ] && [ "$topic" = "security" ] && SEC_GATE_FILES="${SEC_GATE_FILES} ${rf}"
    done < <(n1_rules_for_agent "security-reviewer" "$CHANGED" "$RULES_DIR")
    if [ -n "$SEC_GATE_FILES" ]; then SEC_RULES_BLOCK=$(n1_rules_render $SEC_GATE_FILES); fi
fi
```

`$CR_RULES_BLOCK` non-empty: append to code-reviewer prompt. `[RULE-N]` violations → review FAIL. `$SEC_RULES_BLOCK` non-empty: append to security-reviewer prompt; violations fold into `[SEC-N]` findings. No gate rules: record `"Rule compliance: no gate rules configured."` in review.md.
