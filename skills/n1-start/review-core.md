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
- Codex runs **iff** `n1_codex_preflight "<BASE_BRANCH>"` passes (checks `codex.enabled` with backward compat for `codexReview.enabled`, companion path, CLI availability, AND base branch resolvability) AND **not** `DOC_CONFIG_ONLY`.

Record every skip explicitly in `review.md` (e.g. `"⚠ security-reviewer skipped — no security-relevant surface in diff"`, `"⚠ Codex skipped — documentation/config-only diff"`) so a missing reviewer is never mistaken for a PASS.

## Codex Reviewer (conditional)

Call `n1_codex_preflight "<BASE_BRANCH>"` (from `plugin/lib/config.sh`). Codex is additionally suppressed when `DOC_CONFIG_ONLY` is true.

If `n1_codex_preflight` returns 0 (success) AND `DOC_CONFIG_ONLY` is false:

1. `CODEX` is already set by `n1_codex_preflight` (via `n1_codex_available`). Read model/effort config:
   ```bash
   CODEX_MODEL=$(n1_codex_val 'model')
   CODEX_EFFORT=$(n1_codex_val 'effort')
   : "${CODEX_EFFORT:=medium}"
   ```

2. Spawn Codex review **in parallel** with the Claude reviewers:
   ```bash
   CODEX_STDERR=$(mktemp)
   CODEX_OUTPUT=$(node "$CODEX" review --wait --scope branch --base "<BASE_BRANCH>" \
     ${CODEX_MODEL:+--model "$CODEX_MODEL"} \
     --effort "$CODEX_EFFORT" 2>"$CODEX_STDERR")
   CODEX_EXIT=$?
   ```
   Run this as a single **blocking foreground** Bash call (the `--wait` flag makes the command return only when the review is done). NEVER end your response turn to "wait for Codex" — in headless mode there is no later turn, and the review dies unfinished. If you launched it in the background for parallelism, you MUST block on its completion (e.g. poll/wait on the background task) within the same turn before proceeding to merge findings.

   After the call completes, validate the result:
   - If `CODEX_EXIT != 0`: this is a **Codex failure**. Read `$CODEX_STDERR` (first 20 lines). Enter the retry path (step 4 below).
   - If `CODEX_EXIT == 0` but `CODEX_OUTPUT` is empty or whitespace-only: treat as failure. Log `"⚠ Codex returned empty output (exit 0) — treating as failure"`. Enter the retry path.
   - If `CODEX_EXIT == 0` and `CODEX_OUTPUT` is non-empty: success. Proceed to spawn codex-adapter (step 3).
   - Always clean up: `rm -f "$CODEX_STDERR"` after recording any needed content.

3. After Codex returns successfully, spawn the **codex-adapter** agent (resolve model for `codex-adapter`) to parse raw output into `[CX-N]` structured findings.

4. **Partial-failure handling:** If the Codex call failed (non-zero exit or empty output), retry once using the same command. If the retry also fails, proceed with the remaining reviewers' findings. Record the gap in review.md with the **actual error** — do NOT interpret or diagnose the cause; quote stderr verbatim:
   - Format: `"⚠ Codex review did not complete (exit <CODEX_EXIT>). stderr: <first 20 lines of CODEX_STDERR>"`
   - If both attempts produced empty output: `"⚠ Codex review returned empty output on both attempts (exit 0 both times)"`

If `n1_codex_preflight` returns 1 (unavailable) OR `DOC_CONFIG_ONLY` is true → capture the stderr from the preflight call and log `"⚠ Codex skipped — <stderr reason, or 'documentation/config-only diff'>"` in review.md and treat Codex as NOT running (this affects the code-reviewer scope decision below).

Let **CODEX_ACTIVE** be true only when all of these hold: `n1_codex_preflight` passed, `DOC_CONFIG_ONLY` is false, and the Codex call did not permanently fail after its retry.

## code-reviewer Scope (Codex-aware delegation)

- **If CODEX_ACTIVE:** Codex owns whole-diff general correctness (a genuine cross-model, uncorrelated channel), so narrow the `code-reviewer` to the dimensions nothing else covers. Add this directive to its spawn: *"Codex (a cross-model reviewer) owns whole-diff general correctness and bug hunting for this review. **Override section 4 of your default process:** report ONLY (a) Test Quality `[TQ-N]` findings — including the TQ-High assertion-rewriting gate — and (b) design-intent / convention-adherence findings evaluated against `brainstorm.md` (when available). Do NOT perform a general correctness/bug sweep; skip Correctness, Edge cases, and performance dimensions."*
- **If NOT CODEX_ACTIVE:** `code-reviewer` runs its **full default scope** (whole-diff correctness + TQ + design-intent) — no diverse channel exists. Add no scope-narrowing directive.
