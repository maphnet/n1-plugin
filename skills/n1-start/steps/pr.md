
> **After this step completes, IMMEDIATELY continue to the next pipeline step (FINALIZE MEMORY) — do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**

Do not read full reports — n1-pr extracts what it needs via `grep`; tech-writer reads files directly.

Resolve `prMode`: `git.prMode` if present; else `git.draftPR === false` → `"ready"`; else → `"draft"`.

<!-- n1:step-snippet-exception: pre-PR review gate fence runs before the step begins (N1-439) -->
**Pre-PR review gate** (N1-439; skip when `prMode` is `"skip"`): a commit made after Step 7 with no head record (local-test fix, 7b TQ fix, regression fix, "Fix manually", ad-hoc) makes `n1_review_pin set` refuse the PR head, so it is re-reviewed here first.
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/pr-step.sh"
n1_pr_gate
```
- `PRE_PR_GATE=0` or `2`: continue (`2`: review.md verdict not PASS, e.g. Step 8 **Exhausted**; a re-review must not clear open findings, so n1-pr's pin refusal is the intended stop).
- `1` (no review step ran or its artifacts are missing; the call empties `fix.diff` so the review runs at full scope): count it like `3` (same cap, same cap handling below); do not invoke n1-pr; run Step 7, then Step 8 when the verdict routes there, then this step again. Do not re-run Step 9 (local testing already ran for this diff; its bounded loop and `local_test_fix_cycle` persist, and re-entering it after exhaustion would re-escalate).
- `3` (HEAD is past the review head chain; the call wrote `fix.diff` from the last reviewed head, empty when unknown): `PRE_PR_REVIEW_CYCLE` below 3 → return to Step 7 (`review_fix_cycle` ≥ 1 reviews `fix.diff` incrementally, else full scope); Step 8 follows when the verdict routes there (Step 9 is not re-run), then this step again. At 3 (for `1` or `3`) → § Autonomy Gate with step=`pr`, action=`proceed to PR unreviewed`, ledger_context=`HEAD not at the review chain end; pre-PR re-review cap reached`; on that action add `- [UNREVIEWED-HEAD] High — commits after the last review were not re-reviewed` under `## For Human Review` in review.md (file-write) and continue (n1-pr refuses the pin; a human reviews before merge). Prompt otherwise: 1. Proceed to PR unreviewed (Recommended: the cap is reached, the same choice fix.md **Exhausted** recommends) 2. Re-review once more (return to Step 7). **Headless:** `procedures/autonomy-headless.md § Headless Guard`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/pr-step.sh"
n1_step_begin "pr" 12
n1_pr_entry
```

`FIX_AUDIT` other than `ok`, including empty (review fix cap bypassed): before n1-pr, ensure review.md lists `- [FIX-CAP] High — review_fix_cycle past the cap without an [asked] ledger row` under `## For Human Review` (file-write; create the section if absent) so the PR body shows it; never an `[auto]` pass.

**If `prMode` is `"skip"`**: skip n1-pr/push/`## Pending`; add ledger row, run the last block below (end `skipped`), continue.

**Run n1-pr:** `route:worker` → follow `procedures/pr-worker-dispatch.md`; `route:inline`, or that procedure's `pr:prompt` or `pr:unknown` → invoke skill `n1:n1-pr`. Pass: `docUpdateMode: "autonomous"`.

> **ORCHESTRATOR GUARDRAIL (post-PR follow-ups):** do not add post-PR actions inline (CI watch, finish, smoke) — these are separate pipeline steps invoked after this step completes.

**Post-condition (skip when `prMode` is `"skip"`):** every open PR on this branch must have a Codex receipt (n1-pr step 1 or 3); a hand-written `gh pr create` does not count.
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/codex-review.sh"
MISSING=$(n1_review_check_run)
[ -z "$MISSING" ] || { echo "ERROR: n1-pr Codex step not run for: $MISSING" >&2; exit 1; }
```
On exit 1, do not continue: run n1-pr step 3 (`skills/n1-pr/steps/03-codex-review.md`) once per branch, then re-run this check.

After PR created: record `## Pending` section in `$N1_HOME/memory/$ID/overview.md` (idempotent upsert):
```markdown
## Pending
awaiting: merge
pr: <PR number>
pr_url: <PR URL>
branch: <branch name>
last_checked: <date -u +%Y-%m-%dT%H:%M:%SZ>
created: <same timestamp>
```

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/pr-step.sh"
n1_pr_outcome || { n1_step_end "pr" 12 failed; exit 1; }
n1_step_end "pr" 12 "<success|skipped>"
```

Gate 3 (emitted in FINALIZE MEMORY) carries `PR: <url>` — do not print CHECKPOINT here.

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
