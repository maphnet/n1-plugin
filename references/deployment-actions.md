# Procedure: Deployment Actions

Runs the deploy-time actions a PR declares in its body. Called from n1-finish (Step 2 before the merge, Step 4 after the deploy) and n1-release (Step 2 collect, Step 3 gate, Step 5 before the tag push, Step 8b after the deploy). Never dispatches a persona. `### Before release` items are walked only by n1-release (Step 5, before the tag push); n1-finish never offers them and reports them as deferred to release.

**Contract** (tech-writer writes it at PR time; the PR body is the source of truth):

```markdown
## Deployment Actions

### Before deploy
- [ ] `<shell command>`
- [ ] Manual: <step — names only, never secret values>

### Before release
- [ ] Manual: <release-time step, e.g. prod-only — walked only by n1-release before the tag push>

### After deploy
- [ ] `<shell command>`
- [ ] Check: <read-only verification and its expected result, e.g. the health endpoint returns 200>
```

One action per `- [ ]` line. An item starting with `Manual:` is always a **manual item**. An item starting with `Check:` is a **check item**: a read-only verification written in prose; § Check composes and runs the read-only commands, and a `Check:` item is never a shell item, even when it contains backticks. Otherwise it is a **shell item** only when it starts with a backtick, contains exactly two backticks, and the extracted command is non-empty; its command is the text between the backticks, extracted by § Command. Everything else is a **manual item**. `- [x]` means done: it is never offered again. Secret values never appear, only names.

The per-run working copy is a TSV file, one row per unticked item: `<PR>\t<orig phase: before|after|release>\t<phase: before|after|drop>\t<item text>`. § Parse sets the orig-phase and phase columns identically, except a `### Before release` item, which gets orig phase `release` and phase `before`. § Edit may later change only the phase column (move/drop); the orig-phase column stays put, so § Tick can still find the item under the heading it actually lives under in the PR body. Rows are addressed by row number `K` (the `cat -n` number), so item text is never pasted into a shell command. Paths: n1-finish uses `$N1_HOME/scratch/deploy-actions-<PR>.tsv`; n1-release uses `$N1_HOME/scratch/release-actions.tsv`. § Parse also writes `"$OUT.deferred"` (same row format; scratch only, rewritten on every Parse).

**Queue and headless runs** (`N1_QUEUE_RUN_ID` non-empty or `N1_HEADLESS=1`, printed as `mode:runbook`) never run § Walk. The one exception: n1-finish Step 4 and n1-release Step 8b run § Check on `after` check rows once a deploy was watched and succeeded in this run (a resumed pending deploy alone does not count), never otherwise. For everything else, n1-finish uses § Runbook and n1-release reports the rows.

## § Parse

```bash
source ~/.n1/preamble.sh
PRS="<PR numbers, space-separated>"
OUT="<TSV path>"
RELEASE_ROWS="defer"
if [ -n "${N1_QUEUE_RUN_ID:-}" ] || [ "${N1_HEADLESS:-}" = "1" ]; then echo "mode:runbook"; else echo "mode:walk"; fi
mkdir -p "$(dirname "$OUT")"; : > "$OUT"; : > "$OUT.deferred"; rm -f "$OUT.cmd"
for n in $PRS; do
  if ! BODY=$(gh pr view "$n" --json body --jq .body 2>/dev/null); then echo "fetch-failed:#$n"; continue; fi
  printf '%s\n' "$BODY" | tr -d '\r' | awk -v pr="$n" -v rel="$RELEASE_ROWS" -v def="$OUT.deferred" '
    /^## / { in_da = ($0 ~ /^## Deployment Actions[[:space:]]*$/); phase = ""; next }
    in_da && /^### / { phase = ($0 ~ /^### Before deploy/) ? "before" : (($0 ~ /^### After deploy/) ? "after" : (($0 ~ /^### Before release/) ? "release" : "")); next }
    in_da && phase != "" && /^- \[ \] / {
      sub(/^- \[ \] /, "")
      if (phase != "release") print pr "\t" phase "\t" phase "\t" $0
      else if (rel == "include") print pr "\trelease\tbefore\t" $0
      else print (pr "\trelease\tbefore\t" $0) >> def }' >> "$OUT"
done
echo "unticked:$(wc -l < "$OUT" | tr -d ' ')"
echo "deferred:$(wc -l < "$OUT.deferred" | tr -d ' ')"
awk -F'\t' '{ s = $4; for (i = 5; i <= NF; i++) s = s "\t" $i; print "deferred #" $1 " " s }' "$OUT.deferred"
cat -n "$OUT"
```

`fetch-failed:#<n>`: that PR's actions are unknown. The caller decides whether to stop or continue.

`RELEASE_ROWS` selects how `### Before release` items are handled. `defer` (default; n1-finish) writes them to `"$OUT.deferred"` and prints `deferred:<M>` plus one `deferred #<PR> <item>` line each; they never count in `unticked` and never reach § Walk, § Tick or § Runbook. `include` (n1-release sets `RELEASE_ROWS="include"`) writes them to `$OUT` as `before` rows with orig phase `release`, so every `before`-row rule below applies to them.

§ Walk, § Command, § Check, § Tick, § Conflicts, § Unwatched Deploy and § Runbook are in `references/deployment-actions-rows.md` (same plugin root). When § Parse printed `unticked:<N>` or `deferred:<M>` above 0, or a step cites one of those sections, read that file first.
