
**Telemetry (if enabled):** Emit `started_at` for step 9 (`review`) before spawning reviewers. This applies to both the initial review and any re-review pass after a fix cycle:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/telemetry.sh"
n1_emit_step_event "$N1_RUN_ID" "$N1_VERSION" "$ID" "review" 9 "${N1_HOME}/memory/$ID/telemetry" started_at=now
```

**Ensure dependencies (worktree mode).** Run the **Ensure Dependencies(`<ID>`)**
procedure before any reviewer that may execute lint/typecheck tooling.
Marker-guarded no-op on the normal path.

> **ORCHESTRATOR GUARDRAIL (review): do not run tests, coverage, or lint commands in this step. Reviewers and the developer (fix mode) run what they need; the orchestrator only reads their returned findings and routes them.**

**Shared review core:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/review-core.md` with `<BASE_BRANCH>` = the recorded branch point when available, else the `git.defaultBranch` value from `$N1_HOME/config.json`:
```bash
BP_FILE="$N1_HOME/memory/<ID>/branch-point"
BASE_BRANCH=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || echo "<git.defaultBranch from config>" )
```
(The branch-point file pins the review diff to THIS ticket's commits; diffing against `git.defaultBranch` balloons to the whole parent branch when the run started from a non-default branch.) It defines the diff-surface classification (DOC_CONFIG_ONLY, SECURITY_RELEVANT) and reviewer selection with skip-recording.

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer (if SECURITY_RELEVANT)

Resolve models for code-reviewer (with context `review`) and security-reviewer (with context `review`).

Prepare review context (curated per reviewer, not one identical bundle):

Generate the cold-review inputs first (the reviewer must not see the author's narrative):
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/memory.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/treestate.sh"
MEM="$N1_HOME/memory/$ID"
{
  echo "# Review Spec (generated — acceptance criteria and chosen approach only)"
  n1_extract_sections "$MEM/brainstorm.md" "acceptance criteria" "chosen approach|selected approach|decision"
  [ -s "$MEM/brainstorm.md" ] || n1_extract_sections "$MEM/ticket.md" "acceptance criteria" "requirements"
} > "$MEM/review-spec.md"
{
  echo "# QA Facts (generated — evidence only, no narrative)"
  n1_extract_sections "$MEM/qa.md" "evidence" "break-check" "tests run"
  if [ -n "${BREAK_CHECK_TQ:-}" ]; then
    echo "## Hollow tests (break-check never-red or inconclusive)"; echo "$BREAK_CHECK_TQ" | sed 's/^/- /'
  fi
} > "$MEM/qa-facts.md"
TREE_BEFORE=$(n1_tree_snapshot "<worktree dir>")
```
- **Shared:** the PATHS `$MEM/ticket.md` and `$MEM/qa-facts.md` (instruct each reviewer: "Read these files yourself; their content is NOT inlined here"), the base branch name, and the `## Key Decisions` + `## Escalations` slices of `overview.md` inline — so neither reviewer flags a deliberate, recorded choice as a defect.
- **code-reviewer also receives** the paths `$MEM/review-spec.md` and, when it exists, `$MEM/plan.md`. It does **NOT** receive `implementation.md` or `brainstorm.md`: the reviewer is a cold second pair of eyes and must derive what changed from the diff, not from the author's account. Add the directive: **"You are a cold second pair of eyes. Review the code that is actually there against the spec. Do not assume intent the code does not demonstrate. Identify changed files with `git diff --name-only <BASE_BRANCH>...HEAD`."**
- **code-reviewer also receives** `testCoverage.tier` value (same value read in Step 6) — for Test Quality evaluation calibration. Also read `qa_verdict_unverified` from overview.md frontmatter:
  ```bash
  source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
  QA_UNVERIFIED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified")
  ```
  When `QA_UNVERIFIED=true`, append this directive to the code-reviewer prompt (immediately after the `testCoverage.tier` line): **"QA verdict is unverified (evidence missing from qa.md). Treat the QA pass as unconfirmed when evaluating Test Quality — apply additional scrutiny to any test coverage claims."**
  When `qa-facts.md` lists hollow tests, add: **"The listed tests stayed green with the fix reverted. Report each as a `[TQ-N]` finding (Medium) unless the diff shows it is a pure refactor guard."**
- **security-reviewer does NOT receive** `review-spec.md`, `plan.md`, or `testCoverage.tier` — keep its context lean: `ticket.md` acceptance criteria + changed-file list + the diff.

Spawn all selected reviewers simultaneously:
- **code-reviewer** with the code review context (scoped per the rule above) — always.
- **security-reviewer** with the security review context — only if `SECURITY_RELEVANT`.

After ALL return, merge findings:
- **Tree freeze check.** `n1_tree_verify "$TREE_BEFORE" "<worktree dir>"`. If it fails, the tree moved while reviewers ran (a reviewer or a stray process edited, staged, or committed). Discard ALL findings from this pass, increment `review_discarded_count` in overview frontmatter (`n1_increment_counter`), record `n1_append_key_decision ... "Review discarded: working tree changed during review (cycle N)"`, and re-run the reviewers once from "Spawn agents in PARALLEL". If the second pass also fails the check → § Autonomy Gate (qualityEscalations) with step=`review`, action=`proceed with the second pass findings and flag the review as tree-unstable in review.md`.
- Combine outputs into `$N1_HOME/memory/<ID>/review.md`
- Prefix code-reviewer findings with [CR-N], security-reviewer with [SEC-N]. Code-reviewer `[RULE-N]` findings keep their prefix (not remapped).
- Combined verdict: FAIL if any confirmed **Critical or High** findings exist across all reviewers, or any `[RULE-N]` findings exist. Medium and Low findings are reported in `review.md` but do not block the pass — consistent with n1-review Phase 4 threshold.
- **Partial-failure handling:** if any reviewer errors, times out, or returns malformed output, retry that reviewer once. If it still fails, proceed with the remaining reviewers' findings, record the gap explicitly in review.md, and do NOT treat the missing reviewer as a PASS.

**Fingerprint recording:** After merging all findings, record fingerprints for all confirmed Critical and High findings:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/fingerprints.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
CYCLE=${CYCLE:-1}
```

For each confirmed Critical or High finding (from code-reviewer or security-reviewer), compute and append — the angle-bracket values are per-finding placeholders, not literals: substitute the finding's actual ID (e.g., `CR-1`, `SEC-2`), its actual severity (`Critical` or `High`), and the actual file path and title from the finding:

```bash
FP=$(n1_fingerprint_finding "<file_path>" "<finding_title>")
n1_fingerprint_append "$FP_FILE" "$FP" "<finding_id>" "<severity>" "active" "$CYCLE"
```

**Convergence guard (re-review cycles only):** After recording fingerprints, check convergence when `review_fix_cycle > 0`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/fingerprints.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
CYCLE=${CYCLE:-0}
if [ "$CYCLE" -gt 0 ]; then
    if ! n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE"; then
        # Non-convergence: blocking count did not decrease from previous cycle to current cycle
        # Escalate immediately — do not burn remaining fix cycles
        # Context: "Review findings are not converging (blocking count: <prev> -> <new>). Continuing fix cycles is unlikely to resolve the remaining issues."
    fi
fi
```

On non-convergence (blocking count for cycle N is not less than cycle N-1), escalate to the user immediately using the same escalation protocol as bound exhaustion, with context: "Review findings are not converging. Continuing fix cycles is unlikely to resolve the remaining issues."

**Headless:** under `N1_HEADLESS=1`, apply SKILL.md § Headless Guard instead of prompting.

Update overview: `[x] Review`, set `step: review`

### 7b. TQ FIX LOOP (if TQ findings exist)

After merging review findings, check code-reviewer output for `[TQ-N]` findings at Medium severity or above.

**If no TQ findings at Medium+:** Skip to Step 8.

**If TQ findings at Medium+ exist:**

1. Extract the TQ findings from `review.md`
2. Spawn **qa-engineer** (not developer) with:
   - The TQ findings (what to fix/remove)
   - The path to current `qa.md` — instruct the agent: "Read `$N1_HOME/memory/<ID>/qa.md` yourself — your original test work. Its content is NOT inlined here."
   - `testCoverage.tier` value
   - Directive: "**TQ Fix Mode — skip your standard 6-step process.** The code-reviewer flagged these test quality issues. Your only task: remove or rewrite the specific tests identified in the TQ findings below. After making those changes, run the test suite to confirm no regressions. Do not follow Steps 1–5 of your normal process."
   - Output-path directive: "Write your full QA Report (your standard Output Format) to `$N1_HOME/memory/<ID>/qa.md` yourself, as a full overwrite (never append). Return to the orchestrator ONLY this compact block:
     `Verdict: PASS|FAIL` / `Bugs found: yes|no` (one line per bug if yes) / `TQ-relevant notes: <one line or none>` / a 3–5 sentence summary of the test work. Do NOT return the full report — followed by your n1:signals line per your Signal Emission section."
3. After QA returns:
   - The qa-engineer updated `$N1_HOME/memory/<ID>/qa.md` itself (verify non-empty as in Step 6; fallback-write the returned summary if not)
   - Run via Bash:
     ```bash
     source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
     n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "tq_fix_cycle"
     ```
4. After QA fixes TQ findings, proceed to Step 8. No re-review needed — TQ findings are non-blocking.
5. **Bounded:** `tq.maxFixAttempts` (config, default 2) — a separate counter from the Step 6 QA bug-fix loop so QA exhaustion never blocks TQ cleanup. Before spawning, check the bound:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
   TQ_MAX=$(n1_config_val '.tq.maxFixAttempts' '2')
   # exhausted when tq_fix_cycle (overview.md frontmatter) >= TQ_MAX
   ```
   On exhaustion:

   **Autonomy gate:** → § Autonomy Gate (qualityEscalations) with step=`review`, action=`log remaining TQ findings in review.md and proceed to Step 8`, ledger_context=`<TQ findings that remained unresolved after N attempts>`.

   **Headless:** under `N1_HEADLESS=1`, apply SKILL.md § Headless Guard instead of prompting.

   If `QE` is `ask`: log remaining TQ findings in `review.md` and proceed to Step 8 — non-blocking findings do not stall the pipeline.

If combined verdict remains FAIL after Step 7b, proceed to Step 8 (FIX). The bound is `review.maxFixAttempts` (config in `$N1_HOME/config.json`, default 3 — the `review_fix` `max_default` in `pipeline.json`). When `review_fix_cycle` has reached the bound, escalate via the autonomy gate below instead of entering another fix cycle.

**Autonomy gate:** → § Autonomy Gate (qualityEscalations) with step=`review`, action=`accept remaining findings and continue`, ledger_context=`<findings that remained unresolved after N fix cycles>`.

**Headless:** under `N1_HEADLESS=1`, apply SKILL.md § Headless Guard instead of prompting.

If `QE` is `ask`: compose `PREAMBLE` (title from `$N1_HOME/memory/<ID>/overview.md` heading + Core Ask from `ticket.md`; omit if unavailable). **Bug root cause (bug tickets only):** Source `"${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"` first, then: if `$N1_HOME/memory/<ID>/analysis.md` contains a `### Bug Investigation` section AND the `has_bug_root_cause` signal is strictly `true` (read via `n1_read_signal`), prepend one sentence summarizing the root cause: `"Root cause: {root cause}. "` — prepend this to `PREAMBLE`. If the signal is `false`, absent, or any other value, omit the root cause line entirely. Then: "{PREAMBLE} After `review.maxFixAttempts` (default 3) review cycles, these findings remain unresolved: [list]. Please advise."

**On PASS verdict:** Treat the review as PASS and proceed to the next pipeline step.
