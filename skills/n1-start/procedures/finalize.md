# Procedure: Finalize Memory

## Finalize Memory (Step 12)

Update overview.md: all checkboxes checked; `step: done`; add `docs_updated` field if doc updates occurred; add final status line.

**Telemetry:**
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/telemetry.sh"
n1_close_run
```
`$FINAL_OUTCOME`: `pr_created`/`pr_skipped`/`escalated`/`failed`. `$ESTIMATED_TIER`: overview tier or empty.

Clear active-run (first record any run-branch PR still missing its Codex receipt, so the Stop hook enforces it after the pointer is gone):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
n1_review_check_run >/dev/null
n1_active_run_clear
```

**Follow-ups** (`qualityEscalations=auto-accept` only): append any follow-up you would otherwise propose per `<N1_ROOT>/references/followup-filing.md` § Append (source `finalize`), then run `<N1_ROOT>/references/followup-filing.md` § File. Never offer to file them.

**Emit Gate 3** (`procedures/output-gates.md § Gate 3`). Sources:
1. `$N1_HOME/memory/$ID/implementation.md` — `## Implementation Summary`
2. `$N1_HOME/memory/$ID/qa.md` — verdict + Evidence (verbatim)
3. `$N1_HOME/memory/$ID/local-testing.md` — report (verbatim, or SKIPPED line)
4. `$N1_HOME/memory/$ID/overview.md` — `## Pending` for PR URL; frontmatter `ticket_url` for tracker link
5. § File report line → `Follow-ups:` (omit if § File skipped)

Copy test commands and result lines verbatim. Every skipped step gets `SKIPPED — <reason>`. `Ticket:` omitted when `ticket_url` is empty. PR URL is Gate 3's final field (or `PR: SKIPPED` if skipped). Investigation tickets: use investigation-mode variant.

**Chain** (last, after Gate 3; do not yield first): only if `$FINAL_OUTCOME` is `pr_created`/`pr_skipped`, `source ~/.n1/preamble.sh; n1_fullauto_enabled` prints `true`, and CI passed, had no checks, or was skipped — never after failed or escalated CI — invoke skill `n1-finish` with args `<ID> chained` (never n1-release).
