# Step 3b: Dev Observability Scan

Runs after Step 3 every time, also when Step 3 printed "Automated run skipped". Step 3's skip conditions do not apply here, and `dev-access.md` is optional input.

The scan surfaces errors on dev since the previous `v*` tag. It only reads: call no provider tool other than the one operation named below, and never change provider state. Nothing in this step adds to `WARN` or `PUBLISH_FAIL`, changes Step 3 results, or files a ticket.

## 3b-1. Gate

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
DIR="$N1_HOME/releases/<LABEL>"
rm -f "$DIR/dev-observability.md" "$DIR/obs-rows.tsv" "$DIR/obs-groups.tsv"
PREV="<PREV, or empty>"
[ -n "$PREV" ] || { echo "obs:skip Dev observability skipped: no previous tag, nothing to compare against."; exit 0; }
SINCE=$(n1_release_tag_date "$PREV")
[ -n "$SINCE" ] || { echo "obs:skip Dev observability skipped: tag date for $PREV not found locally."; exit 0; }
PROVIDERS=$(n1_release_obs_providers)
[ -n "$PROVIDERS" ] || { echo "obs:skip dev observability not configured"; exit 0; }
echo "since=$SINCE now=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "window=$(n1_release_obs_window "$PREV")"
while IFS= read -r p; do echo "provider: $p"; done <<<"$PROVIDERS"
[ -f "$N1_HOME/dev-access.md" ] && echo "hints:yes" || echo "hints:no"
```

- `obs:skip <line>`: print `<line>`, write it as the only content of `$DIR/dev-observability.md` with the file-write mechanism, and go to Step 4. The rest of the run is unchanged.
- Otherwise keep `since`, `now` and `window=<H> <full|capped> <B>`. `H` is the scan window in hours from the previous tag's creation date. `B` is the baseline reach in hours: twice `H`, capped at `N1_OBS_MAX_HOURS` (default 720). Each `provider:` line is `<name><TAB><mcp><TAB><kind><TAB><tool>`. Only `env: dev` providers are listed, whatever `observability.default` says.

## 3b-2. Query each provider

Handle the providers one at a time, with one bounded call each. Search the tool list for `mcp__<mcp>__<tool>`.

- Tool not found: record `<name>: unavailable (tool not loaded)` and move on.
- The call errors or times out: record `<name>: unavailable (<reason>)` and move on. Keep only the characters `[A-Za-z0-9 :._-]` of the reason, at most 80.
- An unavailable provider never fails the run, and it is not a warning or a publish failure.

Selectors: with `hints:yes`, read `$N1_HOME/dev-access.md` § Observability hints. A stream selector or filter there that applies to this service wins over the provider's `instructions`. Otherwise follow the provider's `instructions`. Take parameter names from the tool's own schema.

- `loki`: error-level lines from the service streams. Use the selector, filtered on the `level` label or field when the streams have one, else with the line filter `|~ "(?i)(error|exception|fatal|panic)"`. Parameters: `direction=backward`, `limit=500`, `start=<B>h`. Lines older than `since` give the baseline for `pre-existing`.
- `sentry`: query `is:unresolved environment:dev`, `period=<H>h`, `limit=100`, newest first. The dev project can be shared with prod, so never drop the environment filter. When the hints or instructions name another dev environment, use that name.
- `langfuse`: exceptions from the last `<B>h`, at most 100.

Record each provider that answered as `<name>: ok (<N> rows; query: <the query string you sent>)`.

Write the results to `$DIR/obs-rows.tsv` with the file-write mechanism. Never paste provider text into a snippet. Write one row per result, `<first-seen><TAB><last-seen><TAB><count><TAB><text>`, with tabs and newlines inside text replaced by spaces:

- Loki line: its timestamp twice, `1`, the log line.
- Sentry issue: `firstSeen`, `lastSeen`, its event count, the title and culprit.
- Langfuse exception: its timestamp twice, `1`, the exception message.

Keep timestamps as the provider returns them (ISO-8601 or epoch seconds, ms, µs or ns). When no provider returned rows, write an empty file.

## 3b-3. Group

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
DIR="$N1_HOME/releases/<LABEL>"
[ -f "$DIR/obs-rows.tsv" ] || : > "$DIR/obs-rows.tsv"
n1_release_obs_group "$(n1_release_tag_date "<PREV>")" < "$DIR/obs-rows.tsv" > "$DIR/obs-groups.tsv"
awk -F'\t' '{n[$5]++} END {printf "groups=%d new=%d pre=%d\n", NR, n["new since release"], n["pre-existing"]}' "$DIR/obs-groups.tsv"
```

Each `obs-groups.tsv` row is `<signature><TAB><count><TAB><first seen><TAB><last seen><TAB><new since release|pre-existing><TAB><sample>`, newest last seen first. The signature and sample are already redacted and safe for a table cell. Copy these cells verbatim. Never copy text from `obs-rows.tsv` or from a provider response into the section, the page or a snippet.

- A `dropped: <N>` line: record `Dropped rows: <N>`.
- `pre=0` while a `loki` or `langfuse` provider returned rows: no error was seen both before and since the tag. Record `Baseline: no error seen both before and since the tag; new/pre-existing unconfirmed for <provider names>`. Sentry's `firstSeen` needs no baseline.
- `window=` said `capped`: record `Window capped at <H>h; errors older than that are not seen`.

## 3b-4. Attribute and write the section

For each of the first 20 rows, name the most likely in-scope ticket. Compare the signature, the sample and that group's rows in `obs-rows.tsv` (stack-trace paths, endpoints, messages) with `$DIR/release.diff` and the in-scope ticket list. Write a ticket ID only when it matches `^<PREFIX>-[0-9]+$` and is in the scope; otherwise write `unattributed`. Rows after the first 20 are `unattributed`. The table lists at most 50 rows; state how many were left out.

Write `$DIR/dev-observability.md` with the file-write mechanism:

```markdown
- Window: since <PREV> tagged <since> to <now> (queried <H>h, <full, or capped at N1_OBS_MAX_HOURS>)
- Providers: <each "<name>: ok (<N> rows; query: <query>)" or "<name>: unavailable (<reason>)", separated by "; ">
- Baseline: <"errors seen both before and since the tag", "not needed (Sentry only)", or the note from 3b-3>
- Dropped rows: <N, or none>
- new since release: <N>, pre-existing: <N>, rows not listed: <N>

| Signature | Count | First seen | Last seen | Status | Ticket | Sample |
|---|---|---|---|---|---|---|
| <signature> | <count> | <first seen> | <last seen> | <new since release or pre-existing> | <ID or unattributed> | <sample> |
```

When `groups=0`, replace the table with `No errors found in window.` When every provider was unavailable, keep the provider list and write `No provider answered.` in place of the table. Every cell stays on one line.

## 3b-5. Next actions

Step 4g lists these under each `new since release` row, in the format of `<N1_ROOT>/references/question-format.md`. `pre-existing` rows get none. Nothing is done for the user and no ticket is filed. The Tier 2 evidence is the `UNVERIFIED` item list in `04-publish-report.md` § 4g, which also recommends a re-check first: a group is a log symptom, and its ticket attribution is a text-match heuristic, so it is reproduced before anyone changes code or files a ticket. (The Release Mode PASS rule is not cited: it counts a log line as behavioural evidence, so it does not support this recommendation.)

```
1 — re-check (Recommended): a log or error signature shows a symptom, not a cause, and the ticket attribution is only a text match (same order as the UNVERIFIED list in Step 4g)
2 — make a change: works when the group is attributed to an in-scope ticket and the cause is clear
3 — log a ticket: works when the risk is accepted for this release
```
