
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/review-step.sh"
n1_step_begin "review" 9
n1_review_entry "<worktree dir>" || exit 1
```
Output: `BASE_BRANCH= RELATED_ENABLED= CYCLE= INCREMENTAL=`, `TREE_BEFORE=` and, on `INCREMENTAL=true`, `FIX_FILES=`. Non-zero exit (missing implementation.md, invalid story base): stop the step. The call also removes stale reviewer files and writes review-spec.md and qa-facts.md.

If `RELATED_ENABLED=true`, read `procedures/review-xrepo.md` and follow it before spawning reviewers.

`CYCLE=0`: read `procedures/review-codex.md`; run its **Start** block right after the Review tier gate below unless `REVIEW_TIER=SKIP`; its **Collect**, **Validate** and **Index** parts run after all reviewers return, before **Tree freeze**.

### Incremental Re-Review (cycle >= 1)

If `INCREMENTAL=true`: read `procedures/review-incremental.md` and follow it (code-reviewer and security-reviewer scope). `INCREMENTAL=false`: full scope.

Run **Ensure Dependencies(`<ID>`)** first. > **ORCHESTRATOR GUARDRAIL (review): do not run tests, coverage, or lint commands in this step**

**Shared review core:** `review-core.md` with `BASE_BRANCH`.

**Review tier gate:** If `REVIEW_TIER=SKIP`: record `"Review skipped: DOC_CONFIG_ONLY diff."` in `$N1_HOME/memory/$ID/review.md`, write `## Review` with `PASS (skipped — doc/config only)` to overview, run `n1_step_end "review" 9 "success" "{\"head\":\"$(git rev-parse HEAD)\"}"`, and proceed to next step. If `REVIEW_TIER=NARROW`: spawn code-reviewer with scope restricted to TQ findings only — instruct: "Scope: test quality (TQ) findings only. Do NOT review correctness, design, architecture, or style. Report only [TQ-N] findings (coverage gaps, hollow tests)." If `REVIEW_TIER=FULL`: current behavior (full code-reviewer scope).

**Spawn PARALLEL** code-reviewer+security-reviewer (if `SECURITY_RELEVANT`). Shared: ticket.md, qa-facts.md, base branch, `$N1_HOME/memory/$ID/analysis.md`, Key Decisions+Escalations. Code-reviewer: review-spec.md+plan.md (NOT impl/brainstorm); "cold second pair of eyes"; diff `--name-only`; tier. Security-reviewer: ticket.md+file list+diff (on `INCREMENTAL=true`: fix.diff + `<printed FIX_FILES>`).

```bash
source ~/.n1/preamble.sh
QA_UNVERIFIED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified")
IFS=$'\t' read -r CODE_REVIEWER_MODEL CODE_REVIEWER_EFFORT < <(n1_resolve_agent code-reviewer review)
IFS=$'\t' read -r SECURITY_REVIEWER_MODEL SECURITY_REVIEWER_EFFORT < <(n1_resolve_agent security-reviewer review)
```
`QA_UNVERIFIED=true`: add "QA verdict unverified." Hollow tests→`[TQ-N]` (Medium, unless pure refactor). Spawn reviewers with output paths `$N1_HOME/memory/$ID/review-cr.md` / `…/review-sec.md`; each returns verdict, counts, index.

**Wait contract applies** (see `procedures/output-gates.md § Wait Contract`). Idle until ALL reviewers return before combining findings.

**Pre-existing**: read `procedures/review-preexisting.md` and follow it only after the reviewers return and the **Tree freeze** below passes, before writing review-hdr.md and before routing (PASS or FAIL).

`INCREMENTAL=true`: `procedures/review-extra-round.md § Filter` first. For each Critical/High (also each `[SEC-N]`, except a ` (pre-existing)` one not treated as in-diff: **Pre-existing** above): write `$N1_HOME/memory/$ID/fp-new.tsv` with the file-write mechanism, one line per finding `<id><TAB><severity><TAB><file><TAB><title>` (id bare, e.g. `CR-1`; never put a title or path in a shell command, variable or double-quoted string); the block below records it.

After ALL: **Tree freeze** `n1_tree_verify "<printed TREE_BEFORE>"`. Fail→discard reviewer files+`review_discarded_count`+re-run; 2nd→§ Autonomy Gate. Write `$N1_HOME/memory/$ID/review-hdr.md` with the file-write mechanism: `### Verdict: <PASS|FAIL>`, summed counts, review-core.md notes, all Index lines (cycle 0: plus the `n1_review_codex_index` lines, `procedures/review-codex.md § Index`); the block below cats it and the reviewer files (never Read them). **FAIL** if Critical/High/`[RULE-N]` (except a ` (pre-existing)` `[SEC-N]`: **Pre-existing** above); also any in-diff non-Low `[SEC-N]`, never a `[SEC-N]` Low or ` (pre-existing)` (**PASS** below). Partial (incl. missing/empty reviewer file): retry once.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/review-step.sh"
n1_review_collect <true if security-reviewer was spawned, else false> || exit 1
n1_step_end "review" 9 "success" "{\"head\":\"$(git rev-parse HEAD)\"}"
```
Output: `PARTIAL: <file> missing/empty` (non-zero exit: Partial, retry once as above), `FP_RECORD_FAILED`, `NON_CONVERGING: cycle N` when they apply; always `TQ_MAX=N`.
NON_CONVERGING/FP_RECORD_FAILED→escalate. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

### 7b. TQ FIX LOOP

No `[TQ-N]` Medium+ → skip. `tq_fix_cycle` ≥ `TQ_MAX` → § Autonomy Gate, no increment. Else `n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "tq_fix_cycle"`, then `n1_resolve_agent qa-engineer review`+split; spawn qa-engineer: `$N1_HOME/memory/$ID/review.md` path (`[TQ-N]` only), qa.md, tier, "TQ Fix Mode: remove/rewrite TQ tests only, run suite, skip Steps 1-5."

**FAIL → Step 8** (its **Cap gate** bounds the loop).

**PASS** (hands-off soft policy, N1-116): after the verdict line append `## Deferred Soft Findings` to `$N1_HOME/memory/$ID/review.md` with the file-write mechanism, never a shell command (replace if present), one `- [ID] file:line — title` per Low (`[SEC-N]` Low too, at every cycle incl. 0: not fixed, the PR body counts it), `[TQ-N]` Low, Low `[XREPO-N]`, or unknown-severity non-`[SEC-N]` finding. Never list a ` (pre-existing)` finding not treated as in-diff (filed above); a downgraded one is an ordinary `[SEC-N]`. A finding of any prefix in a `SECURITY_RELEVANT` class (review-core.md) counts as `[SEC-N]`. In-diff non-Low `[SEC-N]` is never soft: FAIL → Step 8 (`review.maxFixAttempts` bounds it). A non-TQ Medium whose title ends ` (correctness)` → Step 8 SOFT-ONLY (one developer pass, no re-review) only when `review_fix_cycle` is 0 or absent (at `review_fix_cycle>=1` it is fix-induced and a soft pass would be unreviewed: defer it, no developer); add every other non-TQ Medium to `## Deferred Soft Findings` (no developer, the PR body lists them); no `(correctness)` Medium → no soft pass, proceed (unchanged). Other Critical/High/`[RULE-N]` always FAIL → Step 8 as above (unchanged).
