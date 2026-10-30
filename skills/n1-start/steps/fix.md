<!-- n1:step-snippet-exception: FAIL/PASS branching: separate asked/auto-decided telemetry, PASS-only counter and step_end -->

```bash
source ~/.n1/preamble.sh
n1_step_begin "fix" 10
n1_verify_dependencies "$N1_HOME/memory/$ID" review.md || { echo "ERROR: review.md missing — cannot fix without findings" >&2; exit 1; }
REVIEW_FIX_CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
[[ "$REVIEW_FIX_CYCLE" =~ ^[0-9]+$ ]] || REVIEW_FIX_CYCLE=0
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer fix)
QE=$(n1_autonomy_val 'qualityEscalations')
```

```bash
source ~/.n1/preamble.sh
PRE_FIX_SHA=$(git rev-parse HEAD)
echo "$PRE_FIX_SHA" > "$N1_HOME/memory/$ID/pre-fix-sha"
```

Run **Ensure Dependencies(`<ID>`)** before spawning. Run `procedures/rules-injection.md` (`agent_name=developer`); append `$RULES_BLOCK` to every developer prompt in this step (re-run the procedure if the block is not at hand).

**FAIL**: spawn developer with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`; pass the `$N1_HOME/memory/$ID/review.md` path and this scope: Critical+High (with `QE=auto-accept`, also all `[SEC-N]` and every non-TQ Medium, fixed in this same pass) plus every `[RULE-N]` finding (any severity), "Record under `## Fix Cycle <N>` in implementation.md (idempotent). Return: commit SHAs, `Findings fixed: N/M`."

**SOFT-ONLY** (review PASS routed here; hands-off soft policy, N1-116): spawn developer the same way, passing the `review.md` path and scope: non-TQ Medium titled `(correctness)` only (the rest stay deferred), "Record under `## Fix Cycle <N> (soft)` in implementation.md (idempotent), N = REVIEW_FIX_CYCLE+1. Return: commit SHAs, `Findings fixed: N/M`, `Findings deferred`." After it returns: no `review_fix_cycle` increment, no re-review, no Return to Step 7; apply the `Findings deferred` Append line below and add each Medium it left unfixed (not `[SEC-N]`) to `## Deferred Soft Findings` in review.md (file-write mechanism, never a shell command), then go to **PASS verdict** (its `**Full-suite:**` line goes under the `(soft)` heading). A failed or partial soft pass never blocks: record it and proceed.

**Wait contract applies** (see `procedures/output-gates.md § Wait Contract`).

**Security findings** (`[SEC-N]`/CVE): append "Fix the entire CLASS — search all variants and fix in one pass."

After developer returns (FAIL or SOFT-ONLY): `qualityEscalations=auto-accept`: append the developer's `Findings deferred` per `<N1_ROOT>/references/followup-filing.md` § Append (source `review`).

FAIL-only (the next two blocks; SOFT-ONLY skips them):
```bash
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
```

FAIL-only:
```bash
source ~/.n1/preamble.sh
PRE_FIX_SHA=$(cat "$N1_HOME/memory/$ID/pre-fix-sha" 2>/dev/null || echo "HEAD~1")
FIX_CHANGED=$(git diff --name-only "$PRE_FIX_SHA" HEAD)
echo "$FIX_CHANGED" > "$N1_HOME/memory/$ID/fix-changed-files"
```
Emit: `<ID> · review fix cycle <N>/<MAX>`. FAIL-only: return to Step 7. Bound: `review.maxFixAttempts` (default 2).

**Escalation:** `QE==auto-accept`+non-security/architecture/public-API: take recommended, A-tier `[auto]` ledger. Otherwise: resolution ladder (codebase→web→command→prior decisions). Fail all: emit `n1_emit_question_event ... "fix" "quality" "asked" "codebase|web|command|prior-decisions"`. Preamble: `"{Title}: {Core Ask}."` Bug: prepend root-cause. Ask: "{PREAMBLE} Ambiguity: [...]. 1.<recommended> 2.<alt> 3.Decide for me." "Decide for me"→web+apply, emit `"auto-decided"`.

**PASS verdict:**
```bash
source ~/.n1/preamble.sh
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
```
`clean_passes < 1` → back to Step 7. `clean_passes >= 1` → proceed.

**Full-suite regression check** (once at PASS): detect `package.json`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod`, `Makefile` (first match). None→skip. Found:
```bash
FULL_SUITE_OUTPUT=$(<discovered-test-command> 2>&1); FULL_SUITE_EXIT=$?
FULL_SUITE_LINES=$(echo "$FULL_SUITE_OUTPUT" | wc -l); [ "$FULL_SUITE_LINES" -gt 100 ] && FULL_SUITE_OUTPUT="[truncated: showing last 100 of $FULL_SUITE_LINES lines]
$(echo "$FULL_SUITE_OUTPUT" | tail -n 100)"
```
Append to `## Fix Cycle <N>`: `**Full-suite:** exit <FULL_SUITE_EXIT> — PASS|FAIL`. When spawning developer for regression fix, pass `$FULL_SUITE_OUTPUT` (already capped) as the failure output. Exit 0: proceed. Non-zero: `MP=$(n1_autonomy_val 'mechanicalPrompts')`. `MP==auto` + first attempt: spawn developer to fix, re-run once. Else: ask "Fix regression or proceed?"

```bash
source ~/.n1/preamble.sh
n1_step_end "fix" 10 "success"
```
