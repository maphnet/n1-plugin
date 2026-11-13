<!-- n1:step-snippet-exception: FAIL/PASS branching, PASS-only counter and step_end -->

```bash
source ~/.n1/preamble.sh
n1_step_begin "fix" 10
n1_verify_dependencies "$N1_HOME/memory/$ID" review.md || { echo "ERROR: review.md missing — cannot fix without findings" >&2; exit 1; }
REVIEW_FIX_CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle")
[[ "$REVIEW_FIX_CYCLE" =~ ^[0-9]+$ ]] || REVIEW_FIX_CYCLE=0
FIX_GATE=$(n1_review_fix_gate "$N1_HOME/memory/$ID/overview.md") || true
FIX_AUDIT=$(n1_review_fix_audit "$N1_HOME/memory/$ID/overview.md") || true
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer fix)
echo "REVIEW_FIX_CYCLE=$REVIEW_FIX_CYCLE FIX_GATE=$FIX_GATE FIX_AUDIT=$FIX_AUDIT"
```

**Rule (N1-260):** `n1_review_fix_gate` (fence above) runs before every FAIL developer dispatch. The orchestrator never fixes findings inline and never dispatches a developer outside this step. Only an Exhausted option-2 answer (`[asked]`, or `[plan]` from queue plan time) raises `review_fix_cycle` after a gate deny; an `[auto]` row never replaces that ask.

**Cap gate** (`review.maxFixAttempts`, default 3, counts FAIL cycles; cycles 2+ need progress: `procedures/review-fix-budget.md § Gate`): `FIX_GATE` other than `allow` → no developer in this step. SOFT-ONLY with `FIX_GATE` not `allow` or `REVIEW_FIX_CYCLE>=1` (a FAIL fix is unreviewed code; a soft pass would be a second unreviewed change): add its `(correctness)` Mediums to `## Deferred Soft Findings` in review.md (file-write mechanism), go to **PASS verdict**. FAIL: **Exhausted** below.

**Exhausted** (FAIL; `procedures/review-fix-budget.md § Exit`): headless (`N1_HEADLESS=1`, queue included), or interactive with no open in-diff non-Low `[SEC-N]` or security-class finding (review-core.md): write `## For Human Review` to review.md (file-write; merge if present), one `- [ID] severity file:line — title` per open Medium-or-higher or `[RULE-N]` finding, open `[SEC-N]` first; add an `[auto]` ledger row `review fix cap reached`; write `## Review` `FAIL (unresolved, human review)` to overview; run **Full-suite regression check** and the last block (no `clean_passes`); next step (the PR opens; a FAIL verdict is never merged). Otherwise (interactive with an open in-diff non-Low `[SEC-N]`/security-class finding always needs this ask; never an `[auto]` row) ask the user: summary, then 1. List them under For Human Review and proceed 2. One more FAIL fix cycle (append a `| fix | quality | A | [asked] | review fix cap reached | One more FAIL fix cycle |` ledger row, then run the increment and FAIL dispatch). Name open `[SEC-N]` IDs with severities in the question. Always mark (Recommended) on 1 (budget spent or no progress recorded by the gate); 2 works when the open findings look fixable in one more cycle (format: <N1_ROOT>/references/question-format.md). `FIX_AUDIT` other than `ok` (including empty): afterwards add `- [FIX-CAP] High — review_fix_cycle past the cap without an [asked] ledger row` under `## For Human Review`.

```bash
source ~/.n1/preamble.sh
PRE_FIX_SHA=$(git rev-parse HEAD)
echo "$PRE_FIX_SHA" > "$N1_HOME/memory/$ID/pre-fix-sha"
```

Run **Ensure Dependencies(`<ID>`)** first, then `procedures/rules-injection.md` (`agent_name=developer`); append `$RULES_BLOCK` to every developer prompt in this step.

FAIL-only, before dispatch:
```bash
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"
```

**FAIL**: spawn developer with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`; pass the `$N1_HOME/memory/$ID/review.md` path and this scope: Critical+High (except a ` (pre-existing)` `[SEC-N]` the user filed; also every in-diff non-Low `[SEC-N]` and every non-TQ Medium except ` (pre-existing)`, fixed in this same pass) plus every `[RULE-N]` finding (any severity), "Record under `## Fix Cycle <N>` in implementation.md (idempotent), N = REVIEW_FIX_CYCLE+1, with one line per in-scope ID: `- [ID] fixed|disputed|needs-decision: <what changed, why it is wrong, or the question>`; never defer one. Return: commit SHAs, `Findings fixed: N/M`."

**SOFT-ONLY** (review PASS routed here; hands-off soft policy, N1-116): spawn developer the same way, passing the `review.md` path and scope: non-TQ Medium titled `(correctness)` only (rest stay deferred), "Record under `## Fix Cycle <N> (soft)` in implementation.md (idempotent), N = REVIEW_FIX_CYCLE+1. Return: commit SHAs, `Findings fixed: N/M`, `Findings deferred`." After it returns: no `review_fix_cycle` increment, no re-review, no Return to Step 7; apply the `Findings deferred` Append line below and add each Medium it left unfixed (not `[SEC-N]`) to `## Deferred Soft Findings` in review.md (file-write mechanism), then run the block below and go to **PASS verdict** (`**Full-suite:**` line under the `(soft)` heading). A failed or partial soft pass never blocks.

SOFT-ONLY, after the developer returns (scope gate first, same as FAIL; then records the post-review head for `n1_review_pin set`):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/review-step.sh"
PRE_FIX_SHA=$(cat "$N1_HOME/memory/$ID/pre-fix-sha")
grep -q '^- \[CX-[0-9]' "$N1_HOME/memory/$ID/review.md" 2>/dev/null && n1_review_fix_scope "$PRE_FIX_SHA"
n1_head_record "$(cat "$N1_HOME/memory/$ID/pre-fix-sha")"
```

**Security findings** (`[SEC-N]`/CVE): append "Fix the entire CLASS — search all variants."

FAIL, after the developer returns: contract check (`procedures/review-fix-budget.md § Contract`; `needs-decision` lines: § Needs decision):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/fingerprints.sh"
FIX_CONTRACT=$(n1_fix_verify_result "$N1_HOME/memory/$ID" "$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" review_fix_cycle)" ${FIX_FINAL:-}) || true; echo "FIX_CONTRACT=$FIX_CONTRACT"
```

After developer returns (FAIL or SOFT-ONLY): append the developer's `Findings deferred` per `<N1_ROOT>/references/followup-filing.md` § Append (source `review`).

FAIL-only (the next two blocks; SOFT-ONLY skips them):
```bash
REVIEW_FIX_MAX=$(n1_config_val '.review.maxFixAttempts'); [[ $REVIEW_FIX_MAX =~ ^[0-9]+$ ]] || REVIEW_FIX_MAX=3; echo "MAX=$REVIEW_FIX_MAX"
```

FAIL-only:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/review-step.sh"
PRE_FIX_SHA=$(cat "$N1_HOME/memory/$ID/pre-fix-sha" 2>/dev/null || echo "HEAD~1")
grep -q '^- \[CX-[0-9]' "$N1_HOME/memory/$ID/review.md" 2>/dev/null && n1_review_fix_scope "$PRE_FIX_SHA"
FIX_CHANGED=$(git diff --name-only "$PRE_FIX_SHA" HEAD)
echo "$FIX_CHANGED" > "$N1_HOME/memory/$ID/fix-changed-files"
git diff "$PRE_FIX_SHA" HEAD > "$N1_HOME/memory/$ID/fix.diff"
```
**Scope gate** (N1-517; FAIL and SOFT-ONLY; only when review.md has `[CX-N]` findings, since Codex text can steer the fix): `push:ok`/`push:none`: continue. `push:blocked ... reset=<sha>`: fix commits touching files outside the Step 7 branch diff were removed (patch in `memory/<ID>/codex-blocked-fix.patch`); warn inline and continue: the re-review sees the reduced fix, and open findings end under `## For Human Review`. `tree:restored patch=<path>`: warn inline, continue. `kept=` or `tree:restore-failed`: STOP and escalate (unvetted commits or edits remain; every push path refuses until `git reset --keep <PRE_FIX_SHA>`).
Emit: `<ID> · review fix cycle <REVIEW_FIX_CYCLE+1>/<MAX>`. FAIL-only: return to Step 7.

**Escalation:** non-security/architecture/public-API: take recommended, A-tier `[auto]` ledger. Security/architecture/public-API: resolution ladder (codebase→web→command→prior decisions); all fail: emit `n1_emit_question_event ... "fix" "quality" "asked" "codebase|web|command|prior-decisions"`. Preamble: `"{Title}: {Core Ask}."` Bug: prepend root-cause. Ask: "{PREAMBLE} Ambiguity: [...]. 1.<recommended> 2.<alt> 3.Decide for me."; "Decide for me"→web+apply, emit `"auto-decided"`.

**PASS verdict:**
```bash
source ~/.n1/preamble.sh
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "clean_passes"
```
`clean_passes < 1` → back to Step 7. `clean_passes >= 1` → proceed.

**Full-suite regression check**: detect `package.json`, `pytest.ini`, `pyproject.toml`, `setup.cfg`, `phpunit.xml`, `go.mod`, `Makefile` (first match). None→skip. Found:
```bash
FULL_SUITE_OUTPUT=$(<discovered-test-command> 2>&1); FULL_SUITE_EXIT=$?
FULL_SUITE_LINES=$(echo "$FULL_SUITE_OUTPUT" | wc -l); [ "$FULL_SUITE_LINES" -gt 100 ] && FULL_SUITE_OUTPUT="[truncated: showing last 100 of $FULL_SUITE_LINES lines]
$(echo "$FULL_SUITE_OUTPUT" | tail -n 100)"
```
Append to `## Fix Cycle <N>`: `**Full-suite:** exit <FULL_SUITE_EXIT> — PASS|FAIL`. Regression-fix developer gets `$FULL_SUITE_OUTPUT` (capped) as failure output. Exit 0: proceed. Exhausted: report-only, no developer. First attempt: spawn developer to fix, re-run once. Else: ask "Fix regression or proceed?"

```bash
source ~/.n1/preamble.sh
n1_step_end "fix" 10 "success" "$(n1_review_fix_outcome "$N1_HOME/memory/$ID")"
```
