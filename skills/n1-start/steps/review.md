
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/treestate.sh"; source "$N1_ROOT/lib/related.sh"
n1_step_begin "review" 9
n1_verify_dependencies "$N1_HOME/memory/$ID" implementation.md || { echo "ERROR: implementation.md missing — aborting review step" >&2; exit 1; }
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_BRANCH=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || n1_config_val '.git.defaultBranch' )
MEM="$N1_HOME/memory/$ID"; rm -f "$MEM/review-hdr.md" "$MEM/review-cr.md" "$MEM/review-sec.md"
{ echo "# Review Spec (generated)"; n1_extract_sections "$MEM/brainstorm.md" "acceptance criteria" "chosen approach|selected approach|decision"; [ -s "$MEM/brainstorm.md" ] || n1_extract_sections "$MEM/ticket.md" "acceptance criteria" "requirements"; } > "$MEM/review-spec.md"
{ echo "# QA Facts (generated)"; n1_extract_sections "$MEM/qa.md" "evidence" "break-check" "tests run"; [ -n "${BREAK_CHECK_TQ:-}" ] && { echo "## Hollow tests (break-check never-red)"; echo "$BREAK_CHECK_TQ" | sed 's/^/- /'; }; } > "$MEM/qa-facts.md"
TREE_BEFORE=$(n1_tree_snapshot "<worktree dir>")
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json"); XREPO_REVIEW_CONTEXT=""
if [ "$RELATED_ENABLED" = "true" ]; then
    XREPO_REGISTERED=$(while IFS=$'\t' read -r slug reason _; do [ -z "$slug" ] && continue; printf '\n- %s (%s)' "$slug" "$reason"; done < <(n1_related_projects "$N1_HOME/config.json"))
    SELF_SLUG=$(basename "$(n1_home)")
    XREPO_KNOWN=$(for cfg in "${HOME}"/.n1/*/config.json; do [ -f "$cfg" ] || continue; peer=$(basename "$(dirname "$cfg")"); [ "$peer" = "$SELF_SLUG" ] && continue; printf '%s\n' "$peer"; done | tr '\n' ',' | sed 's/,$//')
    XREPO_REVIEW_CONTEXT="REGISTERED RELATED PROJECTS:${XREPO_REGISTERED:-(none)}
N1-registered on this machine: ${XREPO_KNOWN}
Check diff for imports/API calls/env vars/service names pointing to N1-registered projects NOT above. Flag each [XREPO-N] (Low, non-blocking)."
fi
CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-0}
INCREMENTAL=false; [ "$CYCLE" -ge 2 ] && [ -f "$N1_HOME/memory/$ID/fix-changed-files" ] && { INCREMENTAL=true; FIX_FILES=$(cat "$N1_HOME/memory/$ID/fix-changed-files"); }
QE=$(n1_autonomy_val 'qualityEscalations'); echo "BASE_BRANCH=$BASE_BRANCH RELATED_ENABLED=$RELATED_ENABLED CYCLE=$CYCLE QE=$QE"
```

### Incremental Re-Review (cycle >= 2)

`INCREMENTAL=true`: pass `$FIX_FILES` as file scope; instruct "Incremental re-review — focus on: [list]; check regressions; verify prior Critical/High and [SEC-N] addressed." `INCREMENTAL=false`: full scope.

Run **Ensure Dependencies(`<ID>`)** before reviewers. > **ORCHESTRATOR GUARDRAIL (review): do not run tests, coverage, or lint commands in this step**

**Shared review core:** `review-core.md` with `BASE_BRANCH`.

**Review tier gate:** If `REVIEW_TIER=SKIP`: record `"Review skipped: DOC_CONFIG_ONLY diff, code-reviewer not needed."` in `$N1_HOME/memory/$ID/review.md`, write `## Review` with `PASS (skipped — doc/config only)` to overview, run `n1_step_end "review" 9 "success"`, and proceed to next step. If `REVIEW_TIER=NARROW`: spawn code-reviewer with scope restricted to TQ findings only — instruct: "Scope: test quality (TQ) findings only. Do NOT review for correctness, design, architecture, or style. Report only [TQ-N] findings for test coverage gaps, hollow tests, and test quality issues." If `REVIEW_TIER=FULL`: current behavior (full code-reviewer scope).

**Spawn PARALLEL** code-reviewer+security-reviewer (if `SECURITY_RELEVANT`). Shared: ticket.md, qa-facts.md, base branch, `$N1_HOME/memory/$ID/analysis.md` (codebase analysis; targeted file:line reads), Key Decisions+Escalations. Code-reviewer: review-spec.md+plan.md (NOT impl/brainstorm); "cold second pair of eyes"; diff `--name-only`; tier. Security-reviewer: ticket.md+file list+diff.

```bash
source ~/.n1/preamble.sh
QA_UNVERIFIED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified")
IFS=$'\t' read -r CODE_REVIEWER_MODEL CODE_REVIEWER_EFFORT < <(n1_resolve_agent code-reviewer review)
IFS=$'\t' read -r SECURITY_REVIEWER_MODEL SECURITY_REVIEWER_EFFORT < <(n1_resolve_agent security-reviewer review)
```
`QA_UNVERIFIED=true`: add "QA verdict unverified." Hollow tests→`[TQ-N]` (Medium, unless pure refactor). Append `$XREPO_REVIEW_CONTEXT`. Spawn reviewers with output paths `$N1_HOME/memory/$ID/review-cr.md` / `…/review-sec.md`; each returns verdict, counts, index.

**Wait contract applies** (see `procedures/output-gates.md § Wait Contract`). Idle until ALL reviewer personas return their results before combining findings.

After ALL: **Tree freeze** `n1_tree_verify "$TREE_BEFORE"`. Fail→discard (`rm -f` the reviewer files)+`review_discarded_count`+re-run; 2nd→§ Autonomy Gate. Write `$N1_HOME/memory/$ID/review-hdr.md` with the file-write mechanism: `### Verdict: <PASS|FAIL>`, summed counts, review-core.md notes, all Index lines; the block below cats it and the reviewer files (never Read the reviewer files). **FAIL** if Critical/High/`[RULE-N]`; with `QE=auto-accept` also any `[SEC-N]` (a Low left after one fix cycle: deferred, below). Partial (incl. missing/empty reviewer file): retry once.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/fingerprints.sh"
MEM="$N1_HOME/memory/$ID"; SEC=<true if security-reviewer was spawned, else false>
FILES=(review-hdr.md review-cr.md); [ "$SEC" = true ] && FILES+=(review-sec.md)
for f in "${FILES[@]}"; do [ -s "$MEM/$f" ] || { echo "PARTIAL: $f missing/empty" >&2; exit 1; }; done
( cd "$MEM" && cat "${FILES[@]}" ) > "$MEM/review.md"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"; CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-1}
[ "$CYCLE" -gt 0 ] && { n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE" || true; }
TQ_MAX=$(n1_config_val '.tq.maxFixAttempts'); TQ_MAX=${TQ_MAX:-2}; echo "TQ_MAX=$TQ_MAX"
n1_step_end "review" 9 "success"
```
For each Critical/High (with `QE=auto-accept`, also each `[SEC-N]`): `n1_fingerprint_append "$FP_FILE" "$(n1_fingerprint_finding "<file>" "<title>")" "<id>" "<severity>" "active" "$CYCLE"`. Non-convergence→escalate. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

### 7b. TQ FIX LOOP

No `[TQ-N]` Medium+ → skip. `tq_fix_cycle` ≥ `TQ_MAX` → § Autonomy Gate, no increment. Else `n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "tq_fix_cycle"`, then `n1_resolve_agent qa-engineer review`+split; spawn qa-engineer: `$N1_HOME/memory/$ID/review.md` path (`[TQ-N]` only), qa.md, tier, "TQ Fix Mode: remove/rewrite TQ tests only, run suite, skip Steps 1-5."

**FAIL → Step 8.** Bound: `review.maxFixAttempts` (default 2). Exhaustion → § Autonomy Gate. **If ask:** findings summary + "Please advise."

**PASS** + `QE=auto-accept` (hands-off soft policy, N1-116): after the verdict line append `## Deferred Soft Findings` to `$N1_HOME/memory/$ID/review.md` (replace if present), one `- [ID] file:line — title` per Low, `[TQ-N]` Low, Low `[XREPO-N]`, or unknown-severity finding, excluding `[SEC-N]`; Low `[SEC-N]` only when `review_fix_cycle>=1` (not fixed; the PR body lists them). A finding of any prefix in a `SECURITY_RELEVANT` class (review-core.md) counts as `[SEC-N]`. `[SEC-N]` findings of any severity are never soft: they go to Step 8 as FAIL (`review.maxFixAttempts` bounds Critical/High/Medium; a Low with `review_fix_cycle>=1` is recorded here, no further cycle). Any other non-TQ Medium → Step 8 SOFT-ONLY (one developer pass, no re-review); none → no soft pass, proceed (unchanged). Other modes: **PASS:** proceed. Critical/High/`[RULE-N]` always FAIL → Step 8 as above (unchanged).
