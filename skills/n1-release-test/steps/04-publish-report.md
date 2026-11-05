# Step 4: Publish and Report

A failed publish call never aborts this step. It warns "Could not <operation>: <error> -- continuing.", adds 1 to `PUBLISH_FAIL`, and the plan stays local. A declined write confirmation counts as a failed write. `PUBLISH_FAIL` starts at 0.

## 4a. Gate

Clear the previous run's page data:

```bash
source ~/.n1/preamble.sh
rm -f "$N1_HOME/releases/<LABEL>/page-body.md" "$N1_HOME/releases/<LABEL>/page-results.tsv"
```

Search the tool list for a tool whose name starts with `mcp__<tracker.mcp>__`. When none is found, set `CONF=skipped:tracker server <tracker.mcp> not available`. Otherwise run the gate snippet of `<N1_ROOT>/skills/n1-release/steps/03b-release-notes.md` § 5c-6 step 1. On `conf:skipped:<reason>`, set `CONF=skipped:<reason>`. Then 4b, 4c and 4e are skipped, nothing is published, and the plan stays local.

When `CONF` is not skipped, resolve the space id as in § 5c-6 step 2 of the same file. Without `kb.spaceKey`, set `CONF=skipped:kb.spaceKey missing (set kb.spaceKey to publish)`.

Below, every call is `mcp__<tracker.mcp>__<operations.X>`.

## 4b. Find the page

The title always names the service, because services can share a Confluence space: `TITLE` is `Release test <SERVICE> <LABEL>`, with `SERVICE` resolved as in § 5c-2 of `03b-release-notes.md`.

1. If `$N1_HOME/releases/<LABEL>/page.txt` has `confluence_page_id:`, call `operations.getArticle` with `{pageId}`. Reuse it only when its `spaceId` equals the configured space id and its `title` equals `TITLE` exactly. CQL indexing can lag, so this check comes first.
2. Otherwise call `operations.searchArticles` with `{cql: 'space = "<spaceKey>" AND title = "<TITLE>" AND type = page', maxResults: 5}`. CQL strings escape `\` as `\\` and `"` as `\"`. A hit whose `title` equals `TITLE` exactly gives `PAGE_ID`; then call `operations.getArticle` with `{pageId}`.

A thrown search or read means the page state is unknown: warn, add 1 to `PUBLISH_FAIL`, and set `CONF=failed:could not read page`. Do not create a page, because it could duplicate one holding QA results. Skip 4c and 4e.

## 4c. Save the page body

When a page was found, save the `body` field of the `getArticle` result verbatim to `$N1_HOME/releases/<LABEL>/page-body.md` as a file. Never paste it into a snippet: page text is human-edited. Keep `version` for 4e.

## 4d. Merge results

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
DIR="$N1_HOME/releases/<LABEL>"
RESULTS="$DIR/release-test-results.md"; [ -f "$RESULTS" ] || RESULTS=/dev/null
PAGE=/dev/null
if [ -f "$DIR/page-body.md" ]; then
  if n1_release_page_results < "$DIR/page-body.md" > "$DIR/page-results.tsv"; then
    PAGE="$DIR/page-results.tsv"
  else
    rm -f "$DIR/page-results.tsv"; echo "page:unparsable"
  fi
fi
# Auto cases take the verifier status (missing = UNVERIFIED). Manual and assisted cases take QA's PASS or FAIL
# from the page; any other value or none is pending (MANUAL).
awk -v r="$RESULTS" -v p="$PAGE" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  FILENAME == r { split($0, c, "|"); if (trim(c[2]) ~ /^RT-[0-9]+$/) st[trim(c[2])] = toupper(trim(c[3])); next }
  FILENAME == p { split($0, c, "\t"); qa[c[1]] = toupper(trim(c[2])); next }
  {
    split($0, c, "|"); id = trim(c[2])
    if (id !~ /^RT-[0-9]+$/) next
    class = tolower(trim(c[5]))
    if (class == "auto") { s = st[id]; if (s != "PASS" && s != "FAIL" && s != "UNVERIFIED" && s != "MANUAL") s = "UNVERIFIED" }
    else { s = qa[id]; if (s != "PASS" && s != "FAIL") s = "MANUAL" }
    print id "\t" trim(c[4]) "\t" class "\t" s
  }
' "$RESULTS" "$PAGE" "$DIR/release-test-plan.md" > "$DIR/case-status.tsv"
cat "$DIR/case-status.tsv"
if [ "$PAGE" != /dev/null ]; then
  awk -F'\t' 'NR == FNR {k[$1]; next} !($1 in k) {print "dropped: " $1 " = " $2}' <(cut -f1 "$DIR/case-status.tsv"; echo) "$PAGE"
fi
```

- `page:unparsable`: do not call `operations.updateArticle` and do not create a page. Print "Confluence page found but its table is not parsable; not updated: <url or page id>", add 1 to `PUBLISH_FAIL`, set `CONF=failed:page table not parsable`, and skip 4e. The local plan is the source of truth for this run.
- `dropped:` lines go in the report. Those Results are not carried to the page.

## 4e. Create or update the page

The page body is:

```markdown
# Release test <SERVICE> <LABEL>

Scope: <PREV>..HEAD, <N> tickets: <ID>, <ID>

| ID | Tickets | Risk | Class | Steps and expected | Result |
|---|---|---|---|---|---|
| RT-01 | <ID> | High | auto | 1) <step> -> <expected> | <status from case-status.tsv> |
| RT-02 | <ID> | Low | manual | 1) <step> -> <expected> | <QA value from page-results.tsv verbatim, or empty> |

QA: enter PASS or FAIL in the Result column of each manual and assisted case. Any other value counts as pending.

## Dev observability

not run (N1-179)
```

Write one row per case in the plan. Every cell stays on one line, `|` is written as `\|`, and the page never uses checkbox list items, because they do not survive Jira and Confluence rendering.

- No page found: call `operations.createArticle` with `{spaceId, title: TITLE, body}`. The result is `{id, title, url}`. Set `CONF=created <url>`.
- Page found: call `operations.updateArticle` with `{pageId, title: TITLE, body, version}`, passing the current `version` from `getArticle` unchanged, because jc-mcp increments it itself. Set `CONF=updated <stored url>`, or `CONF=updated <TITLE> (page <id>)` when no url is stored.

After a create or a successful update, store the page. Paste the url only when it matches `^https://[^[:space:]"$]+$` and the id only when it matches `^[0-9]+$`:

```bash
source ~/.n1/preamble.sh
printf 'confluence_url: %s\nconfluence_page_id: %s\n' "<url, or empty>" "<id>" > "$N1_HOME/releases/<LABEL>/page.txt"
```

**Ticket comments.** Post `Release test plan: <url>` with `operations.addComment` to each in-scope ticket when the page was just created. On an update with a known url, when `operations.getComments` is configured, post only to tickets with no comment containing that url. Without a known url or without `getComments`, post nothing and say so in the report. A failed comment warns and does not change `PUBLISH_FAIL`.

## 4f. Readiness signal

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
DIR="$N1_HOME/releases/<LABEL>"
WARN="<integrity warnings plus publish failures>"
BUILD=unverified
grep -Eq '^Dev build: verified \(.+\)' "$DIR/release-test-results.md" 2>/dev/null && BUILD=verified
cut -f2- "$DIR/case-status.tsv" | n1_release_signal "$BUILD" "$WARN"
```

Print its output unchanged; never reword or override the signal.

## 4g. Final report

```
Release test <LABEL> (<PREV, or "no previous tag">..HEAD, <N> tickets)
Readiness: <signal line>
Conditions:
- <each condition line>
Failures:
- <case ID> (<risk>): <reason>
Unverified:
- <case ID> (<risk>): <reason>
Pending QA: <case IDs>
Dropped page results: <dropped lines, or none>
Integrity warnings: <warnings from Step 1, or none>
Confluence: <CONF>
Plan: <path>
Results: <path, or "not run: <reason>">

## Dev observability
not run (N1-179)
```

Under each failure and unverified item, list the next actions in the format of `<N1_ROOT>/references/question-format.md`. Nothing is done for the user and no ticket is filed. The evidence cites the verifier contract in `agents/post-deploy-verifier.md` § Release Mode (Tier 2).

`FAIL` item:

```
1 — make a change (Recommended): the verifier already re-ran the check and it failed again (Release Mode step 4), so a third run is unlikely to differ
2 — re-check: works when the environment or test data changed since the run
3 — log a ticket: works when the risk is accepted for this release
```

`UNVERIFIED` item:

```
1 — re-check (Recommended): no behaviour was observed (Release Mode, PASS rule), so the case has no verdict yet
2 — make a change: works when the case cannot be tested as written
3 — log a ticket: works when the gap is accepted for this release
```
