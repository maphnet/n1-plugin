---
name: n1-review
description: "Code review with fix loop. No args = review current branch (fix cycle). With PR number = advisory review (report only)."
argument-hint: "[PR#]"
model: opus
effort: medium
---

# N1 Code Review

## Overview

Three-phase code review: **find → verify → report**. Specialized agents hunt for bugs ranked by priority (Critical/High/Medium/Low). A verification pass then rules out false positives before producing the final report.

**Announce at start:** "I'm using the n1-review skill to review the code."

## N1_HOME Resolution

Resolve the N1 state directory at the start of every run. Run via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
N1_HOME=$(n1_home)
```

If `N1_HOME` is empty — N1 is not configured; warn the user.

All config reads use `$N1_HOME/config.json`. All memory paths use `$N1_HOME/memory/$ID/`.

## Model Resolution

When spawning any agent, resolve its model via Bash:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_resolve_model <agent-name>
```

Returns the config override if set, otherwise the agent's frontmatter default.

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

**Shared review core:** Read and follow `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/review-core.md` with `<BASE_BRANCH>` = `${REVIEW_BASE}` (computed in Phase 1). It defines the diff-surface classification (DOC_CONFIG_ONLY, SECURITY_RELEVANT), reviewer selection with skip-recording, the Codex probe + CODEX_ACTIVE gating with retry, and the code-reviewer scope-narrowing directive.

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer (+ Codex reviewer if enabled)

Resolve models for code-reviewer and security-reviewer.

Prepare shared review context:
- What was implemented (from memory or commit messages)
- Original requirements (from ticket.md or brainstorm.md)
- Implementation details (from implementation.md)
- QA results (from qa.md, if available)
- Base SHA: `${REVIEW_BASE}`
- Head SHA: current `HEAD`

Spawn the selected reviewers simultaneously (code-reviewer always; security-reviewer iff `SECURITY_RELEVANT`; Codex iff CODEX_ACTIVE). Each returns findings ranked by priority (Critical → High → Medium → Low).

**Wait for ALL agents/commands to complete before proceeding.**

### Phase 3: Verify Findings (False-Positive Elimination)

After ALL reviewers return, merge their raw findings into a single list ordered by priority. Findings carry their source prefix: `[CR-N]` from code-reviewer, `[SEC-N]` from security-reviewer, `[CX-N]` from codex-adapter (if Codex was enabled and succeeded).

**Spawn agent:** code-reviewer (with adversarial verification prompt)

Resolve model for `code-reviewer`.

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

Resolve model for `developer`.

Pass to developer:
- Confirmed findings (Critical + High only)
- List of affected files
- Scratch-artifact policy: write any throwaway benchmark or investigative/spike test (one answering a current question rather than verifying committed code) under `$N1_HOME/scratch/benchmarks/` or `$N1_HOME/scratch/tests/` (both gitignored; create the directory if needed) — never into the repo's test suite. Fixes that need real regression coverage still get committed tests in the repo as usual. When unsure, default to scratch.

After developer fixes are applied, go back to **Phase 2** (full re-review: find → verify → report).

**Oscillation guard:** fingerprint each confirmed Critical/High finding (file + line + title). If a fix attempt does not reduce the confirmed Critical/High count, or the same fingerprint reappears after being marked fixed, escalate early rather than burning the remaining cycles.

Maximum 3 review-fix cycles before escalating to user.

**If no Critical or High confirmed findings (clean pass):**

Review is clean. Medium and Low findings are included in the final report as suggestions but do not trigger a fix cycle.

Check review count:
- `n1_config_val '.review.minCleanPasses'` (default: 1) — minimum consecutive clean passes required
- If this is clean pass N and N < minCleanPasses → go back to **Phase 2**
- If N >= minCleanPasses → **PASS**

### Phase 5: Final Report

```markdown
## Review Report

### Confirmed Findings (Fixed)
| # | Priority | Finding | File | Fix Applied |
|---|----------|---------|------|-------------|
| 1 | Critical | ... | path:line | commit hash |

### Confirmed Findings (Deferred)
| # | Priority | Finding | File | Reason |
|---|----------|---------|------|--------|

### Dismissed (False Positives)
| # | Original Priority | Finding | Reason Dismissed |
|---|-------------------|---------|------------------|

### Stats
- Review cycles: N
- Raw findings: X → Confirmed: Y → Fixed: Z
- False positives eliminated: N

### Verdict: PASS / FAIL
```

Update N1 memory if available:
- Write `$N1_HOME/memory/$ID/review.md` with the final report
- Update `$N1_HOME/memory/$ID/overview.md` checkbox: `[x] Review`

## Advisory Mode

Report-only review for an existing PR. Same find → verify → report flow, but no fixes applied.

### Step 1: Fetch PR diff

```bash
gh pr diff <PR_NUMBER>
```

Also fetch PR description:
```bash
gh pr view <PR_NUMBER>
```

### Step 2: Find Bugs

**Spawn agents in PARALLEL:** code-reviewer + security-reviewer

Resolve models for both agents.

Provide:
- PR diff as the code to review
- PR description as the requirements

**Wait for ALL agents to complete before proceeding.**

### Step 3: Verify Findings

Same adversarial verification process as Review Loop Phase 3:

**Spawn agent:** code-reviewer (with adversarial verification prompt)

Same adversarial kill mandate and context asymmetry as Phase 3 above: pass only the claim (title, file:line, one-line description), not the original reasoning. The verifier's job is to disprove each finding — survivors are confirmed.

### Step 4: Present Final Report

```markdown
## Review: PR #<number> — <title>

### Critical
- [confirmed findings only]

### High
- [confirmed findings only]

### Medium
- [confirmed findings only]

### Low
- [confirmed findings only]

### Dismissed (False Positives)
- [findings ruled out with reasons]

### Summary
- Raw findings: X → Confirmed: Y → False positives: Z
<overall assessment: approve / request changes / needs discussion>
```

Do NOT apply any fixes. This is advisory only — the user decides what to do with the findings.

## Integration

**Called by:**
- **n1-start** — as the mandatory review loop before PR creation
- **Standalone** — `/n1:n1-review` or `/n1:n1-review #340`

**Invokes:**
- n1 agent: **code-reviewer** — bug finding (Phase 2) and false-positive verification (Phase 3)
- n1 agent: **security-reviewer** — security vulnerability finding (Phase 2)
- n1 agent: **codex-adapter** — Codex output parsing into structured `[CX-N]` findings (Phase 2, conditional on `codex.enabled` / `codexReview.enabled` via `n1_codex_available`)
- n1 agent: **developer** — systematic fix of confirmed findings (Phase 4, review loop mode only)
