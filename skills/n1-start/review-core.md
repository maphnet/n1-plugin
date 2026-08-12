# Review Core — Shared Reviewer Selection & Codex Gating

Single source of truth for the review stage's diff-surface classification, Codex gating, and reviewer scope rules. Followed by BOTH `n1-start` (steps/review.md) and `n1-review` (Phase 2). Before following this file, the caller MUST have defined:

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
- Codex runs **iff** the preflight script reports `available:true` (see below) AND **not** `DOC_CONFIG_ONLY`.

Record every skip explicitly in `review.md` (e.g. `"⚠ security-reviewer skipped — no security-relevant surface in diff"`, `"⚠ Codex skipped — documentation/config-only diff"`) so a missing reviewer is never mistaken for a PASS. Additionally append a Decision Ledger row (`skills/n1-start/ledger.md`) to overview.md for each skipped reviewer: `| review | scope | C | [auto] | Run <reviewer>? | Skipped | Run | <skip reason, e.g. doc/config-only diff> |`.

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

## Codex Reviewer (conditional)

Run the standalone preflight script — it handles ALL checks (enabled flag with backward compat, companion path resolution, CLI availability, base branch verification) and outputs structured JSON:

```bash
CODEX_PREFLIGHT=$(bash "${CLAUDE_PLUGIN_ROOT}/lib/codex-preflight.sh" "<BASE_BRANCH>" 2>&1)
echo "$CODEX_PREFLIGHT"
```

Parse the JSON output. The script always exits 0 and prints exactly one JSON line:
- `{"available":true,"codex_path":"...","model":"...","effort":"..."}` — Codex is ready
- `{"available":false,"reason":"..."}` — Codex is unavailable (reason explains why)

**Do NOT attempt to replicate this logic yourself.** Run the script, read the JSON, branch on `available`.

If `available` is `true` AND `DOC_CONFIG_ONLY` is false:

1. Extract values from the preflight JSON: `codex_path`, `model`, `effort`.

2. Spawn Codex review **in parallel** with the Claude reviewers. Write raw output to a scratch file so it stays out of orchestrator context (the adapter reads it directly):
   ```bash
   CODEX_STDERR=$(mktemp)
   CODEX_ID="${ID:-$(git branch --show-current)}"
   CODEX_SCRATCH="$N1_HOME/scratch"
   mkdir -p "$CODEX_SCRATCH"
   CODEX_RAW="$CODEX_SCRATCH/codex-raw-${CODEX_ID}.txt"
   node "<codex_path>" review --wait --scope branch --base "<BASE_BRANCH>" \
     ${CODEX_MODEL:+--model "$CODEX_MODEL"} \
     --effort "$CODEX_EFFORT" >"$CODEX_RAW" 2>"$CODEX_STDERR"
   CODEX_EXIT=$?
   ```
   Where `CODEX_MODEL` and `CODEX_EFFORT` are from the preflight JSON (`model` and `effort` fields).

   Run this as a single **blocking foreground** Bash call (the `--wait` flag makes the command return only when the review is done). NEVER end your response turn to "wait for Codex" — in headless mode there is no later turn, and the review dies unfinished. If you launched it in the background for parallelism, you MUST block on its completion (e.g. poll/wait on the background task) within the same turn before proceeding to merge findings.

   After the call completes, validate the result:
   - If `CODEX_EXIT != 0`: this is a **Codex failure**. Read `$CODEX_STDERR` (first 20 lines). Enter the retry path (step 4 below).
   - If `CODEX_EXIT == 0` but the output file is empty or whitespace-only (`! [ -s "$CODEX_RAW" ] || ! grep -q '[^[:space:]]' "$CODEX_RAW"`): treat as failure. Log `"⚠ Codex returned empty output (exit 0) — treating as failure"`. Enter the retry path. The retry overwrites the same `$CODEX_RAW` file.
   - If `CODEX_EXIT == 0` and `$CODEX_RAW` contains non-whitespace content: success. Proceed to spawn codex-adapter (step 3).
   - Always clean up: `rm -f "$CODEX_STDERR"` after recording any needed content.

3. After Codex returns successfully, spawn the **codex-adapter** agent (resolve model for `codex-adapter`; default haiku, overridable via `models.codex-adapter` in `$N1_HOME/config.json`). Pass the **absolute path** `$CODEX_RAW` — do NOT inline the file content. The adapter `Read`s the file itself and returns only the structured `[CX-N]` block.

4. **Partial-failure handling:** If the Codex call failed (non-zero exit or empty/whitespace-only output file), retry once using the same command (overwrites `$CODEX_RAW`). If the retry also fails, proceed with the remaining reviewers' findings. Record the gap in review.md with the **actual error** — do NOT interpret or diagnose the cause; quote stderr verbatim:
   - Format: `"⚠ Codex review did not complete (exit <CODEX_EXIT>). stderr: <first 20 lines of CODEX_STDERR>"`
   - If both attempts produced empty output: `"⚠ Codex review returned empty output on both attempts (exit 0 both times)"`

If `available` is `false` OR `DOC_CONFIG_ONLY` is true → log `"⚠ Codex skipped — <reason field from JSON, or 'documentation/config-only diff'>"` in review.md and treat Codex as NOT running (this affects the code-reviewer scope decision below).

Let **CODEX_EXPECTED** be true iff the preflight reported `available:true` AND `DOC_CONFIG_ONLY` is false. This is a **spawn-time** predicate — it does not depend on the Codex CLI call outcome.

Let **CODEX_ACTIVE** be true only when all of these hold: `CODEX_EXPECTED` is true and the Codex call did not permanently fail after its retry. This is a **post-hoc** fact, known only after the Codex CLI call (and optional retry) resolves.

## code-reviewer Scope (Codex-aware delegation)

Narrowing is decided at spawn time using only `CODEX_EXPECTED` (never `CODEX_ACTIVE`, which is unknown until after the Codex CLI call).

- **If CODEX_EXPECTED:** Codex is expected to cover whole-diff general correctness, so narrow the `code-reviewer` to the dimensions nothing else covers. Add this directive to its spawn: *"Codex (a cross-model reviewer) is expected to own whole-diff general correctness and bug hunting for this review. **Override section 4 of your default process:** report ONLY (a) Test Quality `[TQ-N]` findings and (b) design-intent / convention-adherence findings evaluated against `brainstorm.md` (when available). Do NOT perform a general correctness/bug sweep; skip Correctness, Edge cases, and performance dimensions."*
- **If NOT CODEX_EXPECTED:** `code-reviewer` runs its **full default scope** (whole-diff correctness + TQ + design-intent) — no diverse channel exists. Add no scope-narrowing directive.

### Partial-failure recovery (CODEX_EXPECTED but NOT CODEX_ACTIVE)

After the Codex CLI call and retry resolve, if `CODEX_EXPECTED` is true but `CODEX_ACTIVE` is false (Codex permanently failed), the code-reviewer's first pass covered only TQ + design-intent — no reviewer has covered correctness. Re-spawn code-reviewer scoped to ONLY the complement dimensions:

1. Record in `review.md`: `"⚠ Codex permanently failed — re-spawning code-reviewer for correctness complement dimensions."`
2. Let **LAST_CR** = the highest `[CR-N]` number from the first code-reviewer pass (0 if no findings). The re-spawned reviewer continues numbering from `[CR-(LAST_CR+1)]`.
3. Spawn code-reviewer with this directive: *"A prior pass already covered Test Quality and design-intent dimensions. **Override section 4 of your default process:** report ONLY Correctness, Edge cases, and Performance findings. Do NOT report `[TQ-N]` findings or design-intent/convention-adherence findings — those are already covered. Number your findings starting at `[CR-<LAST_CR+1>]`."*
4. Provide the same review context as the original code-reviewer spawn (ticket.md, implementation.md, qa.md, brainstorm.md, testCoverage.tier, Key Decisions + Escalations).
5. Merge its findings into `review.md` alongside the first-pass findings. The combined verdict applies to ALL `[CR-N]` findings (both passes).
