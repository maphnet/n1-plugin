<!-- Purpose: Mode detection, priority levels, Review Loop phases 1-4, Advisory mode steps 1-3. -->

## Mode Detection

- **No arguments + on a feature branch** → Review Loop mode
- **Called from n1-start** → Review Loop mode
- **PR number provided** (e.g., `/n1:n1-review #340`) → Advisory mode

## Priority Levels

All findings use a four-tier priority scale:

| Priority | Label | Criteria |
|----------|-------|----------|
| **Critical** | Blocker | Correctness bugs, security vulnerabilities, data loss/corruption risks |
| **High** | Must fix | Design flaws, missing edge cases, broken contracts, test gaps for critical paths |
| **Medium** | Should fix | Suboptimal patterns, minor edge cases, incomplete error handling |
| **Low** | Nice to have | Style, naming, minor improvements, hardening suggestions |

## Review Loop Mode

Three-phase cycle: find bugs → verify findings → report. If confirmed bugs exist, fix and repeat.

### Phase 1: Collect Context

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
CURRENT_BRANCH=$(git branch --show-current)
```

If on the default branch: "You're on the default branch. Switch to a feature branch first, or provide a PR number for advisory review." **STOP.**

Compute the review base — prefer the branch point recorded by n1-start (pins the diff to this ticket's commits; a defaultBranch diff balloons when the branch started from a non-default branch):
```bash
BP_FILE="$N1_HOME/memory/$ID/branch-point"
REVIEW_BASE=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || git merge-base "$DEFAULT_BRANCH" HEAD )
```

Read N1 memory if available:
- `$N1_HOME/memory/$ID/ticket.md` — original requirements
- `$N1_HOME/memory/$ID/brainstorm.md` — scope and approach decisions
- `$N1_HOME/memory/$ID/implementation.md` — what was built
- `$N1_HOME/memory/$ID/qa.md` — test coverage report

### Phase 2: Find Bugs

**Shared review core:** Read and follow `<N1_ROOT>/skills/n1-start/review-core.md` with `<BASE_BRANCH>` = `${REVIEW_BASE}` (computed in Phase 1). It defines the diff-surface classification (DOC_CONFIG_ONLY, SECURITY_RELEVANT) and reviewer selection with skip-recording.

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer (if SECURITY_RELEVANT)

Before reviewer resolution, read `qa_verdict_unverified` from overview and verify the completed QA report. Set `REVIEW_ASTRA_CONTEXT=final-whole-branch-review` only when `qa_verdict_unverified` is not `true`, `qa.md` contains `Verdict: PASS`, and it contains a `### Evidence` section. Otherwise leave it empty; advisory PR review and review-loop runs without verified QA must omit the third resolver argument.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/frontmatter.sh"
QA_UNVERIFIED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified")
REVIEW_ASTRA_CONTEXT=""
if [ "$QA_UNVERIFIED" != true ] && grep -q '^### Verdict: PASS' "$N1_HOME/memory/$ID/qa.md" && grep -q '^### Evidence' "$N1_HOME/memory/$ID/qa.md"; then
    REVIEW_ASTRA_CONTEXT=final-whole-branch-review
fi
if [ -n "$REVIEW_ASTRA_CONTEXT" ]; then
    IFS=$'\t' read -r CODE_REVIEWER_MODEL CODE_REVIEWER_EFFORT < <(n1_resolve_agent code-reviewer review "$REVIEW_ASTRA_CONTEXT")
    IFS=$'\t' read -r SECURITY_REVIEWER_MODEL SECURITY_REVIEWER_EFFORT < <(n1_resolve_agent security-reviewer review "$REVIEW_ASTRA_CONTEXT")
else
    IFS=$'\t' read -r CODE_REVIEWER_MODEL CODE_REVIEWER_EFFORT < <(n1_resolve_agent code-reviewer review)
    IFS=$'\t' read -r SECURITY_REVIEWER_MODEL SECURITY_REVIEWER_EFFORT < <(n1_resolve_agent security-reviewer review)
fi
```

Pass each selected reviewer its resolved model/effort pair.

Prepare shared review context:
- What was implemented (from memory or commit messages)
- Original requirements (from ticket.md or brainstorm.md)
- Implementation details (from implementation.md)
- QA results (from qa.md, if available)
- Base SHA: `${REVIEW_BASE}`
- Head SHA: current `HEAD`

Spawn the selected reviewers simultaneously (code-reviewer always; security-reviewer iff `SECURITY_RELEVANT`). Each returns findings ranked by priority (Critical → High → Medium → Low).

**Wait for ALL agents/commands to complete before proceeding.**

**Incremental re-review (cycle >= 2):** When the internal review-fix cycle counter is >= 2 and `$N1_HOME/memory/$ID/fix-changed-files` exists, scope both reviewers to only the files listed in that file. Instruct reviewers: "Incremental re-review after fix cycle. Scope: [file list]. Check for fix regressions and verify prior findings were addressed." Cycle 0 or 1: full-scope review (no change).

### Phase 3: Verify Findings (False-Positive Elimination)

After ALL reviewers return, merge their raw findings into a single list ordered by priority. Findings carry their source prefix: `[CR-N]` from code-reviewer, `[SEC-N]` from security-reviewer.

**Zero-findings fast path:** If the merged findings list is empty (zero findings from all reviewers), skip Phase 3 entirely. Record in the review output: `"Verification: skipped (zero findings)."` Proceed directly to Phase 4 clean-pass handling.

**Spawn agent:** code-reviewer (with adversarial verification prompt)

Resolve the adversarial verifier with the same verified-QA gate and model/effort pair. When `REVIEW_ASTRA_CONTEXT` is nonempty, call `n1_resolve_agent code-reviewer review "$REVIEW_ASTRA_CONTEXT"`; otherwise call `n1_resolve_agent code-reviewer review` with no third argument. This prevents advisory PR review and unverified review-loop runs from authorizing the exceptional route.

**Adversarial kill mandate:** The verification agent's job is to **disprove** each finding, not confirm it. Default disposition is FALSE POSITIVE — a finding survives only if the verifier fails to refute it after genuinely trying.

**Context asymmetry:** Pass to the verification agent ONLY the finding claim (title, file:line, and a one-line description of the alleged issue). Do NOT pass the original agent's reasoning, evidence, or recommended fix — this prevents anchoring bias. The verifier must build its own case from the code.

The verification agent MUST for each finding:
1. **Read the actual code** at the referenced file:line
2. **Actively try to disprove it** — look for framework guarantees, caller constraints, type-system protections, test coverage, or upstream validation that neutralizes the alleged issue
3. **Determine verdict:** CONFIRMED (could not disprove — real issue) or FALSE POSITIVE (with the refutation evidence)
4. **Re-assess priority** — a finding may shift priority after deeper analysis

The verification agent returns findings in two groups, using this explicit schema (a verdict-per-finding table, NOT the code-reviewer's default finding schema):

```markdown
## Verification Result

### Confirmed
| # | Orig priority | Re-assessed priority | Finding | File:line | Evidence (what you read that confirms it) |
|---|---------------|----------------------|---------|-----------|-------------------------------------------|

### Dismissed (false positives)
| # | Finding | File:line | Why ruled out (framework guarantee / caller check / test coverage / misread) |
|---|---------|-----------|------------------------------------------------------------------------------|
```

### Phase 4: Route by Severity

Work with **confirmed findings only** (false positives are discarded).

**Clean = no Critical or High findings.** Medium and Low findings are reported but do not block the pass.

**If Critical or High confirmed findings exist:**

**Spawn agent:** developer

Resolve developer through `n1_resolve_agent developer review` (no Astra context), split its tab-separated model/effort pair, and pass both to the spawn.

Pass to developer:
- Confirmed findings (Critical + High only)
- List of affected files
- Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one answering a current question rather than verifying committed code) under `$N1_HOME/scratch/benchmarks/` or `$N1_HOME/scratch/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Fixes that need real regression coverage still get committed tests in the repo as usual. When unsure, default to scratch.

**Fix-the-class directive (security-shaped findings):** Before spawning the developer, scan the confirmed Critical/High findings. If ANY of the following conditions is true — a finding tagged `[SEC-N]`, OR a finding whose title contains any of: injection, XSS, CSRF, authentication, authorization, traversal, deserialization, command execution, SSRF, open redirect, SQL injection, path traversal, RCE — append this directive to the developer spawn prompt:

> "One or more findings are security-shaped. When fixing a security finding, do NOT fix only the specific instance reported. Instead, fix the entire CLASS of the vulnerability: search the codebase for all variants of the same pattern (e.g., all injection points, all unsanitized inputs of the same type, all instances of the same auth bypass pattern) and fix them all in one pass. This prevents variant whack-a-mole where fixing one instance exposes the next variant in the subsequent review cycle."

After developer fixes are applied, increment the internal cycle counter and go back to **Phase 2**.

Also record each confirmed Critical/High finding's fingerprint after every review pass (BEFORE the convergence check):

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/fingerprints.sh"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
# For each confirmed Critical/High finding:
FP=$(n1_fingerprint_finding "<file>" "<title>")
n1_fingerprint_append "$FP_FILE" "$FP" "<finding_id>" "<severity>" "active" "<cycle>"
```

**Convergence guard (re-review cycles only):** After recording fingerprints, check convergence when `cycle > 0`:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/fingerprints.sh"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"
CYCLE=<current review_fix_cycle value>
if [ "$CYCLE" -gt 0 ]; then
    if ! n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE"; then
        # Non-convergence detected — escalate to user immediately
    fi
fi
```

On non-convergence (blocking count for cycle N is not less than cycle N-1), escalate to the user rather than burning remaining cycles. Context: "Review findings are not converging."

Maximum 2 review-fix cycles before escalating to user.

**If no Critical or High confirmed findings (clean pass):**

Review is clean. Medium and Low findings are included in the final report as suggestions but do not trigger a fix cycle.

Check review count:
- `n1_config_val '.review.minCleanPasses'` (default: 1) — minimum consecutive clean passes required
- If this is clean pass N and N < minCleanPasses → go back to **Phase 2**
- If N >= minCleanPasses → **PASS**

## Advisory Mode Steps 1-3

### Step 1: Fetch PR diff

```bash
PR_DIFF=$(gh pr diff <PR_NUMBER>)
DIFF_BYTES=${#PR_DIFF}
if [ "$DIFF_BYTES" -gt 50000 ]; then
  PR_DIFF="${PR_DIFF:0:50000}
[truncated: first 50KB of ${DIFF_BYTES}B shown]"
fi
```

Also fetch PR description:
```bash
gh pr view <PR_NUMBER>
```

### Step 2: Find Bugs

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer

Advisory PR review always omits the third Astra-context argument. Resolve each selected reviewer through `n1_resolve_agent code-reviewer review` or `n1_resolve_agent security-reviewer review`, split the tab-separated model/effort pair, and pass both values to its spawn.

Provide:
- $PR_DIFF (already capped) as the code to review
- PR description as the requirements

**Wait for ALL agents to complete before proceeding.**

### Step 3: Verify Findings

Same adversarial verification process as Review Loop Phase 3:

**Spawn agent:** code-reviewer (with adversarial verification prompt)

Resolve the adversarial verifier with `n1_resolve_agent code-reviewer review`, split its tab-separated model/effort pair, and pass both values to the spawn. Advisory PR review always omits the third Astra-context argument.

Same adversarial kill mandate and context asymmetry as Phase 3 above: pass only the claim (title, file:line, one-line description), not the original reasoning. The verifier's job is to disprove each finding — survivors are confirmed.
