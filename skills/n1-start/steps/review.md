
> **After this step completes, IMMEDIATELY continue to the next pipeline step — do NOT write a summary message or yield to the user.**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/memory.sh"; source "$N1_ROOT/lib/treestate.sh"; source "$N1_ROOT/lib/config.sh"; source "$N1_ROOT/lib/related.sh"
n1_step_begin "review" 9
BP_FILE="$N1_HOME/memory/$ID/branch-point"; BASE_BRANCH=$( [ -f "$BP_FILE" ] && cat "$BP_FILE" || n1_config_val '.git.defaultBranch' )
MEM="$N1_HOME/memory/$ID"
{ echo "# Review Spec (generated)"; n1_extract_sections "$MEM/brainstorm.md" "acceptance criteria" "chosen approach|selected approach|decision"; [ -s "$MEM/brainstorm.md" ] || n1_extract_sections "$MEM/ticket.md" "acceptance criteria" "requirements"; } > "$MEM/review-spec.md"
{ echo "# QA Facts (generated)"; n1_extract_sections "$MEM/qa.md" "evidence" "break-check" "tests run"; [ -n "${BREAK_CHECK_TQ:-}" ] && { echo "## Hollow tests (break-check never-red)"; echo "$BREAK_CHECK_TQ" | sed 's/^/- /'; }; } > "$MEM/qa-facts.md"
TREE_BEFORE=$(n1_tree_snapshot "<worktree dir>")
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json"); XREPO_REVIEW_CONTEXT=""
if [ "$RELATED_ENABLED" = "true" ]; then
    XREPO_REGISTERED=""
    while IFS=$'\t' read -r slug reason repo_path; do [ -z "$slug" ] && continue; XREPO_REGISTERED="${XREPO_REGISTERED}
- ${slug} (${reason})"; done < <(n1_related_projects "$N1_HOME/config.json")
    SELF_SLUG=$(basename "$(n1_home)")
    XREPO_KNOWN=$(for cfg in "${HOME}"/.n1/*/config.json; do [ -f "$cfg" ] || continue; peer=$(basename "$(dirname "$cfg")"); [ "$peer" = "$SELF_SLUG" ] && continue; printf '%s\n' "$peer"; done | tr '\n' ',' | sed 's/,$//')
    XREPO_REVIEW_CONTEXT="
REGISTERED RELATED PROJECTS:${XREPO_REGISTERED:-
(none)}
N1-registered on this machine: ${XREPO_KNOWN}
Check diff for imports/API calls/env vars/service names pointing to N1-registered projects NOT above. Flag each [XREPO-N] (Low, non-blocking)."
fi
echo "BASE_BRANCH=$BASE_BRANCH RELATED_ENABLED=$RELATED_ENABLED"
```

Run **Ensure Dependencies(`<ID>`)** before reviewers. > **ORCHESTRATOR GUARDRAIL (review): do not run tests.**

**Shared review core:** read `<N1_ROOT>/skills/n1-start/review-core.md` with `BASE_BRANCH`.

**Spawn PARALLEL:** code-reviewer + security-reviewer (if SECURITY_RELEVANT). Shared: ticket.md, qa-facts.md, base branch, `## Key Decisions`+`## Escalations` inline. Code-reviewer: review-spec.md+plan.md, NOT implementation.md/brainstorm.md; "cold second pair of eyes"; `git diff --name-only <BASE_BRANCH>...HEAD`; tier. Security-reviewer: ticket.md + changed-file list + diff only.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/frontmatter.sh"
QA_UNVERIFIED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_verdict_unverified")
```
`QA_UNVERIFIED=true`: add "QA verdict unverified." qa-facts hollow tests: `[TQ-N]` (Medium) unless pure refactor. Append `$XREPO_REVIEW_CONTEXT`.

After ALL: **Tree freeze** `n1_tree_verify "$TREE_BEFORE"`. Fail→discard, increment `review_discarded_count`, re-run; 2nd fail→§ Autonomy Gate. Combine: `$MEM/review.md`, prefix `[CR-N]`/`[SEC-N]`. **FAIL** if Critical/High/`[RULE-N]`. Partial: retry once.

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/step.sh"; source "$N1_ROOT/lib/fingerprints.sh"; source "$N1_ROOT/lib/frontmatter.sh"; source "$N1_ROOT/lib/config.sh"
FP_FILE="$N1_HOME/memory/$ID/fingerprints.jsonl"; CYCLE=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "review_fix_cycle"); CYCLE=${CYCLE:-1}
if [ "$CYCLE" -gt 0 ]; then if ! n1_fingerprint_check_convergence "$FP_FILE" "$CYCLE"; then :; fi; fi
TQ_MAX=$(n1_config_val '.tq.maxFixAttempts' '2')
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "tq_fix_cycle"
n1_step_end "review" 9 "success"
```
For each confirmed Critical/High: `n1_fingerprint_append "$FP_FILE" "$(n1_fingerprint_finding "<file>" "<title>")" "<id>" "<severity>" "active" "$CYCLE"`. Non-convergence: escalate. **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

### 7b. TQ FIX LOOP

No `[TQ-N]` Medium+ → skip. Else spawn **qa-engineer**: TQ findings, qa.md, tier, "TQ Fix Mode: remove/rewrite TQ tests only, run suite, skip Steps 1-5." Bounded `tq.maxFixAttempts` (default 2). Exhaustion → § Autonomy Gate.

**FAIL → Step 8.** Bound: `review.maxFixAttempts` (default 3). Exhaustion → § Autonomy Gate. **If ask:** findings summary + "Please advise."

**PASS:** proceed.
