# Procedure: Deployment Actions

Runs the deploy-time actions a PR declares in its body. Called from n1-finish (Step 2 before the merge, Step 4 after the deploy) and n1-release (Step 2 collect, Step 3 gate, Step 5 before the tag push, Step 8b after the deploy). Never dispatches a persona.

**Contract** (tech-writer writes it at PR time; the PR body is the source of truth):

```markdown
## Deployment Actions

### Before deploy
- [ ] `<shell command>`
- [ ] Manual: <step — names only, never secret values>

### After deploy
- [ ] `<shell command>`
```

One action per `- [ ]` line. An item starting with `Manual:` is always a **manual item**. Otherwise it is a **shell item** only when it starts with a backtick, contains exactly two backticks, and the extracted command is non-empty; its command is the text between the backticks, extracted by § Command. Everything else is a **manual item**. `- [x]` means done: it is never offered again. Secret values never appear, only names.

The per-run working copy is a TSV file, one row per unticked item: `<PR>\t<before|after|drop>\t<item text>`. Rows are addressed by row number `K` (the `cat -n` number), so item text is never pasted into a shell command. Paths: n1-finish uses `$N1_HOME/scratch/deploy-actions-<PR>.tsv`; n1-release uses `$N1_HOME/scratch/release-actions.tsv`.

**Queue and headless runs** (`N1_QUEUE_RUN_ID` non-empty or `N1_HEADLESS=1`, printed as `mode:runbook`) never run § Walk. Callers use § Runbook instead.

## § Parse

```bash
source ~/.n1/preamble.sh
PRS="<PR numbers, space-separated>"
OUT="<TSV path>"
if [ -n "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" = "1" ]; then echo "mode:runbook"; else echo "mode:walk"; fi
mkdir -p "$(dirname "$OUT")"; : > "$OUT"; rm -f "$OUT.cmd"
for n in $PRS; do
  if ! BODY=$(gh pr view "$n" --json body --jq .body 2>/dev/null); then echo "fetch-failed:#$n"; continue; fi
  printf '%s\n' "$BODY" | tr -d '\r' | awk -v pr="$n" '
    /^## / { in_da = ($0 ~ /^## Deployment Actions[[:space:]]*$/); phase = ""; next }
    in_da && /^### / { phase = ($0 ~ /^### Before deploy/) ? "before" : (($0 ~ /^### After deploy/) ? "after" : ""); next }
    in_da && phase != "" && /^- \[ \] / { sub(/^- \[ \] /, ""); print pr "\t" phase "\t" $0 }' >> "$OUT"
done
echo "unticked:$(wc -l < "$OUT" | tr -d ' ')"
cat -n "$OUT"
```

`fetch-failed:#<n>`: that PR's actions are unknown. The caller decides whether to stop or continue.

## § Walk

Inputs: `PHASE` (`before` or `after`) and `OUT`. Walk the rows whose second column equals `PHASE`, in row order. Rows in the same phase with identical item text (different PRs) are one action: ask once, run once, and § Tick every one of those rows.

This is an unconditional gate. Ask the user for every item, never auto-resolve, never pick an option on the user's behalf, and never run an item the user has not confirmed in this run.

- Run § Command first, with `K=<row number>`, to classify the item and (for a shell item) extract the command into `"$OUT.cmd"`. Treat the item as a **shell item** only when § Command printed `shell`; `manual` → the Manual item branch below.
- **Shell item**: display the command with `cat "$OUT.cmd"` — never by re-typing the item text — then show:
  ```
  Deployment action (<before|after> deploy, PR #<N>): <item text>
  Command: <contents of "$OUT.cmd">
  Run this?
  1 — Yes
  2 — Skip
  3 — Abort
  ```
  Yes → run:
  ```bash
  source ~/.n1/preamble.sh
  OUT="<TSV path>"
  (cd "$(git rev-parse --show-toplevel)" && bash "$OUT.cmd")
  ```
  and show its output. Exit 0 → § Tick. Non-zero → report the failure and ask `1 — Retry / 2 — Skip / 3 — Abort`. Retry re-runs the same command — the same file, never re-typed.
- **Manual item** (§ Command printed `manual`):
  ```
  Deployment action (<before|after> deploy, PR #<N>): <item text>
  Done?
  1 — Yes, done
  2 — Skip (not done yet)
  3 — Abort
  ```
  Yes → § Tick.
- **Skip** (including skipping a failed command) leaves the item unticked; a later run offers it again.
- **Abort** stops the walk; nothing after it runs. Report which items ran, which were skipped, and which remain.

When `PHASE=before` and at least one item was skipped, ask once after the last item:
```
<K> before-deploy action(s) skipped and still unticked. Continue anyway?
1 — Yes, continue
2 — No, stop here
```
No counts as Abort.

Result: `WALK=complete` or `WALK=aborted`.

## § Command

Extracts row `K`'s command from `$OUT` into `"$OUT.cmd"`, so the bytes shown to the user and the bytes executed are always identical — the model never re-types the command. Applies the same rule as the contract: an item starting with `Manual:` is always a manual item; otherwise it is a shell item only when it starts with a backtick, contains exactly two backticks, and the extracted command is non-empty — any other case is a manual item.

```bash
source ~/.n1/preamble.sh
OUT="<TSV path>"
K=<row number>
rm -f "$OUT.cmd"
ITEM=$(sed -n "${K}p" "$OUT" | cut -f3-)
NBT=$(printf '%s' "$ITEM" | tr -dc '`' | wc -c)
CMD=""
case "$ITEM" in
  'Manual:'*) ;;
  '`'*) if [ "$NBT" -eq 2 ]; then CMD=$(printf '%s' "$ITEM" | awk -F'`' '{ printf "%s", $2 }'); fi ;;
esac
if [ -n "$CMD" ]; then
  printf '%s' "$CMD" > "$OUT.cmd"
  echo "shell"
else
  echo "manual"
fi
```

## § Tick

Marks row `K` as done in its PR body. It runs only after a shell item exits 0 or the user confirms a manual item. The match is scoped to the row's own phase: it only flips a line under the `### Before deploy` / `### After deploy` heading that matches column 2 of row `K` (`before` → `### Before deploy`, `after` → `### After deploy`).

```bash
source ~/.n1/preamble.sh
set -o pipefail
OUT="<TSV path>"
K=<row number>
N=$(sed -n "${K}p" "$OUT" | cut -f1)
PHASE=$(sed -n "${K}p" "$OUT" | cut -f2)
ITEM=$(sed -n "${K}p" "$OUT" | cut -f3-)
HEADING="### After deploy"; [ "$PHASE" = "before" ] && HEADING="### Before deploy"
# Re-fetch right before the edit. Ceiling: last write wins if the body changes between this fetch and the edit.
if BODY=$(gh pr view "$N" --json body --jq .body 2>/dev/null); then
  NEW=$(printf '%s\n' "$BODY" | tr -d '\r' \
    | ITEM="$ITEM" HEADING="$HEADING" awk '
        /^## / { in_da = ($0 ~ /^## Deployment Actions[[:space:]]*$/); phase_ok = 0; print; next }
        in_da && /^### / { phase_ok = (index($0, ENVIRON["HEADING"]) == 1); print; next }
        in_da && phase_ok && !d && $0 == ("- [ ] " ENVIRON["ITEM"]) { print "- [x] " ENVIRON["ITEM"]; d = 1; next }
        { print }
        END { exit !d }')
  if [ $? -eq 0 ]; then
    printf '%s\n' "$NEW" | gh pr edit "$N" --body-file - >/dev/null && echo "ticked:#$N" || echo "tick-failed:#$N"
  else
    echo "tick-missing:#$N"
  fi
else
  echo "tick-failed:#$N"
fi
```

`tick-failed:#<N>` → report "The action ran, but PR #<N> could not be updated. Tick `<item>` by hand." Never re-run the action because of a failed tick.

`tick-missing:#<N>` → the item text no longer matches its phase's section (edited or moved since § Parse ran). Never call `gh pr edit` in this case. Report "Item text changed in PR #<N>; tick it by hand."

Note: concurrent PR-body edits are last-write-wins. If lost ticks are ever observed, add a compare-before-write check.

## § Conflicts

n1-release only. This is a model comparison over the `before`/`after` rows, with no parser. Group rows by the resource each item names (variable, secret, migration, feature flag, table). Flag these cases:
- the same resource set to different values by different PRs;
- one PR deletes or renames what another PR sets;
- a `before` item in one PR that depends on an `after` item in another PR (it would run too early).

Identical text in the same phase is a merged duplicate, not a conflict; § Walk runs it once.

Render at the Step 3 gate (omit empty sub-blocks):
```
Deployment actions (<rows> from PRs #<a>, #<b>):
  Before deploy:
    [3] #41  `gh variable set API_URL --body https://a.example`
    [4] #44  Manual: set secret STRIPE_KEY
  After deploy:
    [5] #41  `npm run backfill`
  Conflicts:
    ! API_URL — #41 sets https://a.example, #45 sets https://b.example (rows 3, 8)
  Merged duplicates:
    = rows 4, 9 (#44, #47) — run once
  Not read: PR #50 (fetch failed — its actions are not included)
```

**Edit** (the gate's `4 — Edit deployment actions`): the user answers in free text: move row K to before or after, drop row K from this release, or keep a flagged conflict as-is. Apply each move or drop:

```bash
source ~/.n1/preamble.sh
OUT="$N1_HOME/scratch/release-actions.tsv"
K=<row number>
P=<before|after|drop>
awk -F'\t' -v OFS='\t' -v k="$K" -v p="$P" 'NR == k { $2 = p } { print }' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
```

Row numbers never change. A dropped row stays unticked in its PR body. After edits, re-check conflicts and render the block again.

## § Unwatched Deploy

The caller reached its after-deploy point with `after` rows, but no deploy was watched, so it is not confirmed live. This is an unconditional gate; never auto-resolve it:
```
<K> after-deploy action(s) pending, but no deployment was watched.
1 — Run them now (the deploy is live)
2 — Leave them unticked for a later run
```
1 → § Walk with `PHASE=after`. 2 → report the rows; they stay unticked in the PR bodies.

## § Runbook

n1-finish only, for queue and headless runs. It never executes an item. It writes the unticked items into the ticket's runbook and marks the ticket deploy-pending. The queue runner then parks the ticket as `awaiting-human` (Reason `awaiting-deploy`), the same handling as the SSH-delivery runbook.

```bash
source ~/.n1/preamble.sh
ID="<ID>"
OUT="<TSV path>"
SHA="<merge SHA, or empty when not merged>"
DIR="$N1_HOME/memory/$ID"; F="$DIR/runbook.md"; OV="$DIR/overview.md"
mkdir -p "$DIR"
if [ -f "$F" ]; then sed '/^## Deployment Actions$/,$d' "$F" > "$F.tmp" && mv "$F.tmp" "$F"; else printf '# Deploy runbook: %s\n' "$ID" > "$F"; fi
{
  printf '\n## Deployment Actions\n\nResume with `n1-finish %s`: it asks before each action and ticks it in the PR body.\n' "$ID"
  printf '\n### Before deploy\n\n'; awk -F'\t' '$2 == "before" { print "- [ ] #" $1 " " $3 }' "$OUT"
  printf '\n### After deploy\n\n'; awk -F'\t' '$2 == "after" { print "- [ ] #" $1 " " $3 }' "$OUT"
} >> "$F"
[ -f "$OV" ] || printf -- '---\n---\n' > "$OV"
n1_write_frontmatter "$OV" deploy_pending true
if [ -n "$SHA" ]; then n1_write_frontmatter "$OV" deploy_merge_sha "$SHA"; fi
echo "runbook:$F"
```

The section is always last in `runbook.md`, so a re-run replaces it instead of duplicating it. `n1_delivery_runbook` (SSH delivery) rewrites the file without this section. The PR body still holds every unticked item, so a resumed `n1-finish` offers them again. The runbook holds item text only (names, never secret values) and is never posted to the tracker.
