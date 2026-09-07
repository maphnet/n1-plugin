# Review Core — Shared Reviewer Selection

Single source of truth for the review stage's diff-surface classification and reviewer scope rules. Followed by BOTH `n1-start` (steps/review.md) and `n1-review` (Phase 2). Before following this file, the caller MUST have defined:

- `<BASE_BRANCH>` — the base branch for the diff. n1-start: the `git.defaultBranch` value from `$N1_HOME/config.json`. n1-review: the `DEFAULT_BRANCH` computed in its Phase 1.

## Diff Surface Classification (run first — drives which optional reviewers spawn)

```bash
BASE=$(git merge-base "<BASE_BRANCH>" HEAD)
CHANGED=$(git diff --name-only "$BASE" HEAD)
```

Classify the changed-file set into two independent booleans:

- **DOC_CONFIG_ONLY** — true iff *every* changed path matches only documentation/config surfaces: `*.md`, `*.txt`, `*.yml`/`*.yaml`, `.gitignore`, `LICENSE`, `CHANGELOG*`. Any other path (source, scripts, etc.) makes this false.
- **SECURITY_RELEVANT** — true iff any changed path or its diff touches a security-relevant surface: authentication/authorization, cryptography, input handling/validation, secrets/credentials, network/HTTP clients, (de)serialization, file/path handling, SQL/query building, or shell/command execution. This is a heuristic over paths and diff content. **Bias toward true when uncertain** — a false positive costs one extra review; a false negative can miss a vulnerability.

Reviewer selection follows directly:
- `code-reviewer` **always runs** (docs still get a quality pass).
- `security-reviewer` runs **iff `SECURITY_RELEVANT`** — skip on doc/config-only or clearly non-security code diffs.

Record every skip explicitly in `review.md` (e.g. `"⚠ security-reviewer skipped — no security-relevant surface in diff"`) so a missing reviewer is never mistaken for a PASS. Additionally append a Decision Ledger row (`skills/n1-start/ledger.md`) to overview.md for each skipped reviewer: `| review | scope | C | [auto] | Run <reviewer>? | Skipped | Run | <skip reason, e.g. doc/config-only diff> | --- |`.

## Gate Rule Injection (conditional)

Resolve gate rules for each reviewer:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/rules.sh"
RULES_DIR=$(n1_rules_dir)
CR_RULES_BLOCK=""
SEC_RULES_BLOCK=""
if [ -n "$RULES_DIR" ] && [ -d "$RULES_DIR" ]; then
    CHANGED=$(git diff --name-only "$BASE" HEAD 2>/dev/null)

    # Gate rules for code-reviewer
    CR_GATE_FILES=""
    while IFS= read -r rf; do
        [ -z "$rf" ] && continue
        enf=$(n1_rule_field "$rf" "enforcement")
        [ "$enf" = "gate" ] && CR_GATE_FILES="${CR_GATE_FILES} ${rf}"
    done < <(n1_rules_for_agent "code-reviewer" "$CHANGED" "$RULES_DIR")
    if [ -n "$CR_GATE_FILES" ]; then
        CR_RULES_BLOCK=$(n1_rules_render $CR_GATE_FILES)
    fi

    # Security-topic gate rules for security-reviewer
    SEC_GATE_FILES=""
    while IFS= read -r rf; do
        [ -z "$rf" ] && continue
        enf=$(n1_rule_field "$rf" "enforcement")
        topic=$(n1_rule_field "$rf" "topic")
        [ "$enf" = "gate" ] && [ "$topic" = "security" ] && SEC_GATE_FILES="${SEC_GATE_FILES} ${rf}"
    done < <(n1_rules_for_agent "security-reviewer" "$CHANGED" "$RULES_DIR")
    if [ -n "$SEC_GATE_FILES" ]; then
        SEC_RULES_BLOCK=$(n1_rules_render $SEC_GATE_FILES)
    fi
fi
```

When spawning reviewers below:
- **code-reviewer**: if `$CR_RULES_BLOCK` is non-empty, append it to the spawn prompt. The code-reviewer's persona includes instructions to produce `[RULE-N]` findings for violations. Any `[RULE-N]` finding causes review **FAIL**.
- **security-reviewer**: if `$SEC_RULES_BLOCK` is non-empty, append it to the spawn prompt. Security-topic rule violations fold into existing `[SEC-N]` findings, tagged with the rule name.

Record in `review.md` when no gate rules exist: `"Rule compliance: no gate rules configured."`
