<!-- Purpose: Phase 5 final report (review loop), Advisory mode step 4 final report, memory update, integration. -->

## Review Loop: Phase 5 — Final Report

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

## Advisory Mode: Step 4 — Present Final Report

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
- n1 agent: **developer** — systematic fix of confirmed findings (Phase 4, review loop mode only)
