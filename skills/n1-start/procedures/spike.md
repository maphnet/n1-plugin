# Spike Variant (investigation-deliverable)

Read only when the step's telemetry block printed `VARIANT=spike`. Never in n1-refine caller mode: refine creates no worktree, commit or push.

A spike answers a feasibility or performance question with a throwaway prototype on branch `spike/<ID>` (fixed name; `git.branchPattern` does not apply). The branch is pushed in interactive, headless and queue runs. No PR is created and the branch is never merged.

## § Prototype

Runs after investigation.md is written and before signals extraction, so the final Verdict feeds `implementable`.

**1. Question type.**
```bash
source ~/.n1/preamble.sh
QTYPE=$(grep -oE '\*\*Question type:\*\* [a-z]+' "$N1_HOME/memory/$ID/investigation.md" | head -1 | sed 's/.*\*\* //')
echo "QUESTION_TYPE=${QTYPE:-other}"
```
Not `feasibility` or `performance`: insert `### Prototype Result` before `### Next Steps` in investigation.md with the line `**Prototype:** none (question type: <QUESTION_TYPE>)`, keep the desk Verdict, and return to the step.

**2. Worktree.**
```bash
source ~/.n1/preamble.sh
case "$ID" in *[!A-Za-z0-9_-]*) echo "spike:invalid-id"; exit 1 ;; esac
MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
DEF=$(n1_config_val '.git.defaultBranch'); DEF="${DEF:-main}"
BASE="$DEF"; git -C "$MAIN" rev-parse -q --verify "refs/remotes/origin/$DEF" >/dev/null && BASE="origin/$DEF"
WT="$MAIN/$(n1_worktree_root)/spike-$ID"
if [ -d "$WT" ]; then
    [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "spike/$ID" ] && [ "$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)" = "$(git -C "$MAIN" rev-parse --git-common-dir)" ] \
        && echo "SPIKE_WT=$WT BASE=$BASE" || echo "spike:worktree-failed"
elif git -C "$MAIN" show-ref -q --verify "refs/heads/spike/$ID"; then
    git -C "$MAIN" worktree add -q "$WT" "spike/$ID" && echo "SPIKE_WT=$WT BASE=$BASE" || echo "spike:worktree-failed"
else
    git -C "$MAIN" worktree add -q --no-track -b "spike/$ID" "$WT" "$BASE" && echo "SPIKE_WT=$WT BASE=$BASE" || echo "spike:worktree-failed"
fi
```
`spike:worktree-failed` or `spike:invalid-id`: insert `### Prototype Result` with `**Prototype:** none (worktree failed)`, keep the desk Verdict, and return to the step (non-blocking).

**3. Developer.** Dispatch persona `developer` with the paths to `$N1_HOME/memory/<ID>/ticket.md` and `$N1_HOME/memory/<ID>/investigation.md` (read yourself), the worktree path `<SPIKE_WT>`, and: "Spike mode: build the smallest prototype that answers the `### Question`, inside `<SPIKE_WT>` only. Commits on `spike/<ID>` are allowed; do not push and do not touch any other branch or the main checkout. No tests, error handling or polish required. Run or measure what the question asks. Write `$N1_HOME/memory/<ID>/spike-result.md` with ## Question, ## Setup, ## Runs, ## Result and a last line `Suggested verdict: VALIDATED|PARTIAL|INVALIDATED — <reason>`. Return a summary of at most 15 lines plus the file path." Wait for the persona to return.

**4. Commit.**
```bash
source ~/.n1/preamble.sh
WT="<SPIKE_WT>"; BASE="<BASE>"
git -C "$WT" add -A && { git -C "$WT" diff --cached --quiet || git -C "$WT" commit -q -m "Prototype spike for $ID"; }
echo "AHEAD=$(git -C "$WT" rev-list --count "$BASE..HEAD") SHA=$(git -C "$WT" rev-parse --short HEAD)"
# secret scan over everything the push would publish (developer commits included)
if git -C "$WT" diff --name-only "$BASE..HEAD" | grep -qiE '(^|/)(\.env[^/]*|id_[a-z0-9]+|[^/]*\.(pem|key|p12|pfx))$' \
   || git -C "$WT" diff --text "$BASE..HEAD" | grep -aE '^\+' | grep -aqiE 'BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9_-]{20,}|(api[_-]?key|secret|token|passw(or)?d)["'"'"' ]*[:=]["'"'"' ]*[A-Za-z0-9/+_.-]{8,}'; then
    echo "SECRET=hit"; else echo "SECRET=none"; fi
```

**5. Verdict.** From `spike-result.md`, replace the `**Verdict:**` line in investigation.md with the suggested verdict; keep the desk Verdict when the file or its `Suggested verdict:` line is missing. When the verdict changed, add one Findings bullet: `- Prototype changed the verdict from <desk> to <new>: <reason> (spike-result.md)`. Insert `### Prototype Result` before `### Next Steps` with `**Prototype:** spike/<ID> @ <SHA>` (`AHEAD=0`: `**Prototype:** none (no prototype commit)`) and `**Result:**` followed by at most 3 lines from ## Result. Leave the rest of Findings and Recommendations as written.

**6. Push** (only when `AHEAD` > 0 and `SECRET=none`; substitute the literal ticket ID for `<ID>`):
```bash
source ~/.n1/preamble.sh
WT="<SPIKE_WT>"; MAIN=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
if git -C "$WT" push -u origin spike/<ID>:spike/<ID>; then
    git -C "$MAIN" worktree remove "$WT" && echo "push:ok worktree:removed" || echo "push:ok worktree:kept $WT"
else
    echo "push:failed worktree:kept $WT"
fi
```
`SECRET=hit`: push nothing and keep the worktree; append ` (push skipped: possible secret in prototype, worktree kept at <path>)` to the `**Prototype:**` line, say "Spike push skipped: possible secret; review <path>." and continue (non-blocking).
`AHEAD=0`: run only `git -C "$MAIN" worktree remove "$WT"` (no `--force`, so a dirty tree stays) and push nothing.
`push:failed`: append ` (push failed, worktree kept at <path>)` to the `**Prototype:**` line, say "Spike push failed; worktree kept at <path>." and continue (non-blocking). `push:ok worktree:kept`: say "Spike worktree kept at <path> (uncommitted changes)." Then return to the step.

## § Follow-up description

Used by Phase 5 "Create new implementation ticket" step 2 and by § Follow-up (queue). Add to the description:

```
## Spike
Verdict: <verdict>. Prototype branch: spike/<ID> (reference only).
Implementation rewrites the solution from scratch on its own ticket branch; do not merge or cherry-pick spike/<ID>.
```
No prototype was pushed: write `Prototype branch: none` in the second line and keep the third line.

## § Follow-up (queue)

Runs from the Phase 5 queue gate (`N1_QUEUE_RUN_ID` set), before the restore block.
```bash
source ~/.n1/preamble.sh
VERDICT=$(grep -oE '\*\*Verdict:\*\* [A-Z]+' "$N1_HOME/memory/$ID/investigation.md" | head -1 | sed 's/.*\*\* //')
echo "VERDICT=${VERDICT:-none}"
```
VALIDATED or PARTIAL: run Phase 5 "Create new implementation ticket" steps 1-6 with these changes: step 1 derives the title from the first recommendation and never asks; step 2 adds § Follow-up description; skip step 7 (the restore below handles this ticket). A failed create, label, link or comment is a warning and never blocks. INVALIDATED or no Verdict: create nothing.

Then log the outcome (`CHOSEN` is `created <newID>`, `skipped: <VERDICT>` or `failed: <short reason without quotes>`):
```bash
source ~/.n1/preamble.sh
OVERVIEW="$N1_HOME/memory/$ID/overview.md"; CHOSEN="<outcome>"
grep -q '^## Decision Ledger' "$OVERVIEW" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$OVERVIEW"
printf '| investigation-deliverable | scope | B | [auto] | Spike follow-up under queue run | %s | Skip follow-up | queue: VALIDATED or PARTIAL creates a linked follow-up | --- |\n' "$CHOSEN" >> "$OVERVIEW"
```
