# Review Core — Shared Reviewer Selection

Used by `steps/review.md` and `n1-review`. Caller must define `<BASE_BRANCH>`.

## Diff Surface Classification

```bash
source "$N1_ROOT/lib/preamble.sh"
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

Reviewer selection: `code-reviewer` runs unless `REVIEW_TIER=SKIP`. When `REVIEW_TIER=NARROW`, code-reviewer scope is TQ-only (test quality findings only — no correctness, design, or architecture review). `security-reviewer` runs iff `SECURITY_RELEVANT`. Record each skip/narrow decision in `review.md` + Decision Ledger row.

## Review Tier

```bash
source "$N1_ROOT/lib/preamble.sh"
LINES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/implementation.md" "lines_changed")
LINES_CHANGED=${LINES_CHANGED:-0}
ALL_LOW_RISK=$(n1_classify_all_low_risk "$CHANGED")
SKIP_DOC_CONFIG=$(n1_review_skip_doc_config)
NARROW_THRESHOLD=$(n1_review_narrow_threshold)
[ "$(n1_host)" = "codex" ] && NARROW_THRESHOLD=$(n1_review_narrow_threshold_codex)
if [ "$DOC_CONFIG_ONLY" = "true" ] && [ "$SKIP_DOC_CONFIG" = "true" ]; then
  REVIEW_TIER="SKIP"
elif [ "$LINES_CHANGED" -le "$NARROW_THRESHOLD" ] && [ "$SECURITY_HINT" != "true" ] && [ "$ALL_LOW_RISK" = "true" ]; then
  REVIEW_TIER="NARROW"
else
  REVIEW_TIER="FULL"
fi
n1_record_decision "review-tier" "$([ "$REVIEW_TIER" = "FULL" ] && echo true || echo false)" "" "tier=$REVIEW_TIER" "lines_changed=$LINES_CHANGED" "doc_config_only=$DOC_CONFIG_ONLY" "security_hint=$SECURITY_HINT" "all_low_risk=$ALL_LOW_RISK" "threshold=$NARROW_THRESHOLD"
echo "REVIEW_TIER=$REVIEW_TIER LINES_CHANGED=$LINES_CHANGED ALL_LOW_RISK=$ALL_LOW_RISK"
```

- **REVIEW_TIER=SKIP**: `DOC_CONFIG_ONLY=true` and `review.skipDocConfigOnly` is `true`. Skip code-reviewer entirely.
- **REVIEW_TIER=NARROW**: `lines_changed` within threshold, not security-relevant, all files are low-risk (deps/style/test/ci). Code-reviewer runs TQ-only scope.
- **REVIEW_TIER=FULL**: All other diffs. Full code-reviewer scope.

Record the tier decision in Decision Ledger on every run.

## Gate Rule Injection

```bash
source "$N1_ROOT/lib/preamble.sh"
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
