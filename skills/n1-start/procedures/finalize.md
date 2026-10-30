# Procedure: Finalize Memory

## Finalize Memory (Step 12)

`$FINAL_OUTCOME`: `pr_created`/`pr_skipped`/`escalated`/`failed`. `$ESTIMATED_TIER`: overview tier or empty.

**Follow-ups** (`qualityEscalations=auto-accept` only): append any follow-up you would otherwise propose per `<N1_ROOT>/references/followup-filing.md` § Append (source `finalize`). Never offer to file them.

**Tail worker:** run `source ~/.n1/preamble.sh; rm -f "$N1_HOME/memory/$ID/gate3.md"; IFS=$'\t' read -r TM _ < <(n1_resolve_agent tail-worker finalize); echo "model:$TM"; echo "memory:$N1_HOME/memory/$ID"`; dispatch persona `tail-worker` with the printed model and only `mode: finalize`, `id`, `final_outcome` and absolute `memory` (printed) and `n1_root` paths; wait. If the first line of `gate3.md` is not `=== <ID> — done ===` (missing, empty, garbled), the worker failed: do its steps in `<N1_ROOT>/agents/tail-worker.md` § Mode: finalize yourself.

**Telemetry:**
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/telemetry.sh"
n1_close_run
```

Clear active-run (first record any run-branch PR still missing its Codex receipt, so the Stop hook enforces it after the pointer is gone):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
n1_review_check_run >/dev/null
n1_active_run_clear
```

**Emit Gate 3** (`procedures/output-gates.md § Gate 3`): print `$N1_HOME/memory/$ID/gate3.md` verbatim.

**Chain** (last, after Gate 3; do not yield first): only if `$FINAL_OUTCOME` is `pr_created`/`pr_skipped`, `source ~/.n1/preamble.sh; n1_fullauto_enabled` prints `true`, and CI passed, had no checks, or was skipped — never after failed or escalated CI — invoke skill `n1-finish` with args `<ID> chained` (never n1-release).
