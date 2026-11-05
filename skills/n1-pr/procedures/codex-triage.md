# Procedure: Codex Triage

Read on demand from `skills/n1-pr/steps/03-codex-review.md` § Triage Gate, only when the Codex review ran, `crossHostReview_autoTriage=true`, and the runner printed `findings:file=<path>`. Already in context: that path, the PR number and URL from step 4, and `ID`.

Triage has no user prompts and never blocks the pipeline: every failure below warns inline and continues. Unattended and headless runs follow exactly the same path.

> **ORCHESTRATOR GUARDRAIL (codex-triage):** the triage persona (`tail-worker`, `mode: codex-triage`) does severity parsing, validation, the fix, the fix report and the triage body, following `<N1_ROOT>/skills/n1-pr/procedures/codex-triage-worker.md`. Do not read, edit, copy or echo the findings file, candidates, confirmed findings, validator or developer output, the fix report or the triage file; handle paths, counts and status lines only. `candidates.md`, `confirmed.md` and the triage file are never written through a shell command (redirect, heredoc, `cp`, `cat`, `printf`, `tee`, `sed -i`): the persona writes them with the file-write mechanism. The only shell operations on them here are the guarded post, `mv` and cleanup below, which pass paths and never content. Never edit files, run formatters or linters, or commit in this procedure.

### Fix Phase

```bash
source ~/.n1/preamble.sh
IFS=$'\t' read -r TRIAGE_MODEL TRIAGE_EFFORT < <(n1_resolve_agent tail-worker codex-triage)
echo "triage_model=$TRIAGE_MODEL maxFixAttempts=$(n1_cross_host_review_val 'maxFixAttempts')"
```

Dispatch persona `tail-worker` with model `$TRIAGE_MODEL` and this input:

```
mode: codex-triage
phase: fix
findings:file=<the path from the runner's findings:file= line>
pr: <PR number> <PR URL>
id: <ID>
branch: <PR branch name>
workspace: <worktree or checkout path>
memory: <$N1_HOME/memory/<ID>>
n1_root: <N1_ROOT>
```

Wait for the persona to return. Its last line is one of:
- `triage:fix state=<S> developer=ran start=<path> headref=<path> repo=<path>`: the developer committed fixes without pushing. Run **Push Gate**.
- `triage:fix state=<S> developer=none`: nothing to fix (or validation was unavailable). Skip the gate; continue to **Report Phase**.
- `triage:fix state=<S> developer=failed`: the developer dispatch failed. Warn inline that it may have left unpushed local commits on the PR branch, skip the gate, and still proceed to **Reconcile PR Body** below by way of **Report Phase**.
- `triage:fix state=unavailable`, no line, or any other text: warn inline "Codex review ran; triage failed; the findings are in the PR's `## Codex Review` comment" and that unpushed local developer commits are possible, then continue to **Step 10: Report**.

### Push Gate

Only after `developer=ran`. Count the cycle and gate the push. The paths come from the `triage:fix` line and are prefix-checked; the gate script fails closed and prints exactly one `push:` status line:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
ID="<the ticket ID>"
PR_NUMBER="<the PR number from step 4>"
VALIDATE_DIR="<the state= path from triage:fix>"
RECONCILE_START_FILE="<the start= path from triage:fix>"
HEAD_REF_FILE="<the headref= path from triage:fix>"
REPO_FILE="<the repo= path from triage:fix>"
case "$ID" in ''|*[!A-Za-z0-9_-]*) echo "push:blocked gate-unavailable"; exit 0;; esac
case "$PR_NUMBER" in ''|*[!0-9]*) echo "push:blocked gate-unavailable"; exit 0;; esac
ok() { case "$1" in *..*|"$N1_HOME/scratch/$2-$PR_NUMBER".*/*) return 1;; "$N1_HOME/scratch/$2-$PR_NUMBER".*) return 0;; esac; return 1; }
ok "$VALIDATE_DIR" codex-validate && ok "$RECONCILE_START_FILE" reconcile-start && ok "$HEAD_REF_FILE" reconcile-head && ok "$REPO_FILE" reconcile-repo || { echo "push:blocked gate-unavailable"; exit 0; }
echo "cross_host_fix_cycle=$(n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "cross_host_fix_cycle")"
bash "$N1_ROOT/scripts/codex-push-gate.sh" "$RECONCILE_START_FILE" "$VALIDATE_DIR/allowed.txt" "$(cat "$HEAD_REF_FILE" 2>/dev/null)" "$REPO_FILE" "$N1_HOME/memory/$ID/codex-blocked-fix.patch"
```

Keep the `push:` line verbatim for **Report Phase** (it holds statuses, shas and paths, never Codex text). `push:blocked` and `push:rejected` mean nothing reached the PR (the persona words the details into the triage reply). When this snippet's own guard printed `push:blocked gate-unavailable`, the gate never ran and the developer's commits stay local: warn inline not to push them. Never dispatch phase `fix` twice in one run. If `cross_host_fix_cycle` >= `maxFixAttempts`, proceed to **Reconcile PR Body** below by way of **Report Phase**, like every other outcome. Default `maxFixAttempts=1` means a single pass.

### Report Phase

Dispatch persona `tail-worker` again with model `$TRIAGE_MODEL` and this input:

```
mode: codex-triage
phase: report
state: <the state= path from triage:fix>
push: <the push: line verbatim, or push:skipped when the gate did not run>
cross_host_fix_cycle: <the counter value, or 0>
pr: <PR number> <PR URL>
id: <ID>
memory: <$N1_HOME/memory/<ID>>
n1_root: <N1_ROOT>
```

Wait for the persona to return. It returns three lines: `triage:file=<path> report=<path|none> followups=<n>`, a `Summary:` counts line and a `By severity:` counts line. If it returns no `triage:file=` line, warn inline that triage failed and the findings are in the PR's `## Codex Review` comment, then run the **Triage Reply** snippet with an empty triage path (it prints `triage:bad-path` and still cleans up).

### Reconcile PR Body

Only when `report=` is `<S>/fix-report.md` for the `<S>` from `triage:fix` and `<S>` is a `$N1_HOME/scratch/codex-validate-<PR>.*` directory without `..` (the same prefix rule as the Push Gate; anything else: skip and warn). Follow `<N1_ROOT>/references/reconcile-pr-body.md` (§ Check → § Dispatch → § Apply) with `PR_NUMBER`, `START_FILE` set to the `start=` path from `triage:fix`, and `fix report file: <the report= path>` instead of a verbatim fix report. It no-ops unless the fix cycle pushed. Never blocks: continue to Triage Reply.

### Triage Reply

Post the persona's triage file unchanged. Replace the placeholders with paths and values from the status lines only.

Then post it and clean up:

```bash
source ~/.n1/preamble.sh
PR_NUMBER="<the PR number from step 4>"
case "$PR_NUMBER" in ''|*[!0-9]*) echo "triage:bad-pr-number"; exit 1;; esac
ID="<the ticket ID>"
TRIAGE_FILE="<the path from triage:file=, or empty>"
case "$TRIAGE_FILE" in
  "$N1_HOME"/scratch/codex-triage-"$PR_NUMBER".*/*) echo "triage:bad-path";;
  "$N1_HOME"/scratch/codex-triage-"$PR_NUMBER".*)
    if gh pr comment "$PR_NUMBER" --body-file "$TRIAGE_FILE"; then echo "triage:posted"; rm -f "$TRIAGE_FILE"
    else
      echo "triage:comment-failed"
      case "$ID" in
        ''|*[!A-Za-z0-9_-]*) echo "triage:fallback-unavailable file=$TRIAGE_FILE";;
        *) mkdir -p "$N1_HOME/memory/$ID" && mv -f "$TRIAGE_FILE" "$N1_HOME/memory/$ID/codex-triage.md" && echo "triage:fallback file=$N1_HOME/memory/$ID/codex-triage.md" || echo "triage:fallback-unavailable file=$TRIAGE_FILE";;
      esac
    fi;;
  *) echo "triage:bad-path";;
esac
VALIDATE_DIR="<the state= path from triage:fix, or empty>"
case "$VALIDATE_DIR" in "$N1_HOME"/scratch/codex-validate-"$PR_NUMBER".*/*) ;; "$N1_HOME"/scratch/codex-validate-"$PR_NUMBER".*) rm -rf "$VALIDATE_DIR";; esac
RECONCILE_START_FILE="<the start= path from triage:fix, or empty>"
case "$RECONCILE_START_FILE" in "$N1_HOME"/scratch/reconcile-start-"$PR_NUMBER".*/*) ;; "$N1_HOME"/scratch/reconcile-start-"$PR_NUMBER".*) rm -f "$RECONCILE_START_FILE";; esac
HEAD_REF_FILE="<the headref= path from triage:fix, or empty>"
case "$HEAD_REF_FILE" in "$N1_HOME"/scratch/reconcile-head-"$PR_NUMBER".*/*) ;; "$N1_HOME"/scratch/reconcile-head-"$PR_NUMBER".*) rm -f "$HEAD_REF_FILE";; esac
REPO_FILE="<the repo= path from triage:fix, or empty>"
case "$REPO_FILE" in "$N1_HOME"/scratch/reconcile-repo-"$PR_NUMBER".*/*) ;; "$N1_HOME"/scratch/reconcile-repo-"$PR_NUMBER".*) rm -f "$REPO_FILE";; esac
```

`triage:comment-failed` with `triage:fallback file=<path>`: the persona's file was moved there unchanged (a path operation, never a content write); warn inline with that path. `triage:fallback-unavailable file=<path>`: warn inline with the scratch path, which stays in place. `triage:bad-path` (the `triage:file=` path is not a `$N1_HOME/scratch/codex-triage-<PR>.*` file): nothing was posted, the other cleanups still ran; warn inline that the findings are in the PR's `## Codex Review` comment.

Report result, copying the persona's two counts lines:
```
Codex triage: posted as PR comment (or: moved to memory as fallback)
<the persona's Summary: line>
<the persona's By severity: line>
```

Continue to **Step 10: Report** in `<N1_ROOT>/skills/n1-pr/steps/03-codex-review.md`.
