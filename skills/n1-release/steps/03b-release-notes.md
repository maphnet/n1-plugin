# Step 5c: Release Notes

Writes plain-language release notes for non-developer stakeholders in three forms: a Slack-ready block, a full version published to Confluence, and a stakeholder section at the top of the GitHub Release body.

Modes:
- `MODE=normal`: reached from Step 5b, or straight from Step 5 when Step 5b's gate was false. This step runs whether or not 5b ran. `TAG`, `VERSION`, `PREV_TAG`, `release-prs` (Step 2, sub-step 7) and the release URL are already known. If Sources C and D of `RELEASE_TICKET_IDS` (Step 2, sub-step 6) were not merged yet, merge them now. Skip 5c-1 and 5c-5. The Step 3 gate already covered the writes below.
- `MODE=notes-only`: reached from the `--notes [<TAG>]` routing in SKILL.md. Steps 1 to 5b did not run. This mode ends at 5c-8 and STOPs, with no Step 6, 8, 8b or 9.

Every sub-step is best-effort, as in Step 5b. A failure warns `Could not <operation> for <target>: <error> -- continuing.` and never blocks the report. The Slack block is always produced. This step dispatches no persona. Shell variables do not survive between bash calls, so state lives in files under `$N1_HOME/scratch/` and `$N1_HOME/releases/`.

## 5c-1. Notes-only setup (`MODE=notes-only` only)

```bash
source ~/.n1/preamble.sh
TAG="<TAG argument, or empty>"
case "$TAG" in v*|"") ;; *) TAG="v$TAG" ;; esac
[ -z "$TAG" ] && TAG=$(git tag --list 'v*' --sort=-version:refname | head -1)
if [ -z "$TAG" ] || ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "notes:no-tag"
else
  # Previous tag = the next older v* tag, so an older TAG gets its own range, not the latest one.
  PREV_TAG=$(git tag --list 'v*' --sort=-version:refname | awk -v t="$TAG" 'f {print; exit} $0 == t {f = 1}')
  echo "TAG=$TAG VERSION=${TAG#v} PREV_TAG=$PREV_TAG"
  gh release view "$TAG" --json url --jq .url 2>/dev/null || echo "release:none"
fi
```

- `notes:no-tag`: report "No release tag found. Pass one: `/n1:n1-release --notes <TAG>`." and STOP.
- `release:none`: say "No readable GitHub Release for <TAG>; its body will not be updated." Then continue. The notes file and Confluence still run, and 5c-7 reports `body:no-release`.
- `release-prs`: run the sub-step 7 snippet from `01-resolve-metadata.md` with two changes. Set `RELEASE_TARGET="<TAG>"`, and remove the pending-batch loop. Do not parse deployment actions.
- `RELEASE_TICKET_IDS`: run Sources C and D of `01-resolve-metadata.md` sub-step 6 with this `TAG` and `PREV_TAG`, and merge them. Sources A and B do not apply.

## 5c-2. Service and title (both modes)

This is the same resolution as `03-tracker-release.md` § 5b-0, but without its prompts or persist steps. A missing `ticketTagging.service` silently falls back to the directory name.

```bash
source ~/.n1/preamble.sh
VERSION="<VERSION>"
SERVICE=$(n1_config_val '.ticketTagging.service')
[ -z "$SERVICE" ] && SERVICE=$(basename "$(git rev-parse --show-toplevel)")
TPL=$(n1_config_val '.release.trackerRelease.versionName')
[ -z "$TPL" ] && TPL="{serviceName} {version}"
VERSION_NAME=$(echo "$TPL" | sed "s/{serviceName}/$SERVICE/g; s/{version}/$VERSION/g")
# Services can share a Confluence space, so the title always names the service.
case "$VERSION_NAME" in *"$SERVICE"*) TITLE="$VERSION_NAME release notes" ;; *) TITLE="$VERSION_NAME $SERVICE release notes" ;; esac
echo "VERSION_NAME=$VERSION_NAME"; echo "TITLE=$TITLE"
```

## 5c-3. Gather sources

PRs: write one block per release PR, using the PR's `## Summary` section (or the title alone when there is none):

```bash
source ~/.n1/preamble.sh
TAG="<TAG>"; PRS="<release-prs, space-separated, or empty>"
OUT="$N1_HOME/scratch/release-notes-sources-$TAG.md"
mkdir -p "$N1_HOME/scratch"; : > "$OUT"
for n in $PRS; do
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  if J=$(gh pr view "$n" --json title,url,body 2>/dev/null); then
    { printf '## PR #%s %s\nurl: %s\n' "$n" "$(jq -r .title <<<"$J")" "$(jq -r .url <<<"$J")"
      jq -r .body <<<"$J" | tr -d '\r' | awk '/^## /{f = ($0 ~ /^## Summary/); next} f'
      echo; } >> "$OUT"
  else
    printf '## PR #%s (could not read)\n\n' "$n" >> "$OUT"
  fi
done
echo "sources:$OUT"
```

Tickets: when `tracker.mcp` and `tracker.operations.readTicket` are set, read each ID in `RELEASE_TICKET_IDS` with `mcp__<tracker.mcp>__<operations.readTicket>`. On failure, warn per ticket and continue. Append one line per ticket. The heredoc is quoted, so ticket text is never expanded:

```bash
source ~/.n1/preamble.sh
cat >> "$N1_HOME/scratch/release-notes-sources-<TAG>.md" <<'EOF'
## Ticket <ID> | <issue type> | <summary>
EOF
```

`release-prs` is empty on a first release, so the sources file may be empty. That is not an error.

## 5c-4. Compose

First, read the Confluence lines stored by an earlier run. Keep them when you rewrite the file:

```bash
source ~/.n1/preamble.sh
mkdir -p "$N1_HOME/releases"
grep -E '^confluence_(url|page_id): ' "$N1_HOME/releases/<TAG>.md" 2>/dev/null || echo "stored:none"
```

Read `$N1_HOME/scratch/release-notes-sources-<TAG>.md`, then write `$N1_HOME/releases/<TAG>.md` (overwrite) in this shape:

```
# <TITLE>
confluence_url: <stored url>
confluence_page_id: <stored page id>

## Slack

*<TITLE>*

*New*
• <one plain sentence>

*Improved*
• <one plain sentence>

*Fixed*
• <one plain sentence>

## Full

### New
- <one plain sentence>

### Improved
- <one plain sentence>

### Fixed
- <one plain sentence>

### Internal changelog
- <ticket link or key> <ticket summary> ([#<PR number>](<PR url>))
```

Writing rules:
- Write the two `confluence_` lines only when 5c-4's read found them. Never invent them.
- Group by judgement, using the ticket type as a hint: Bug goes to Fixed; Story, Feature or Epic to New; Task, Improvement, Sub-task or an unknown type to Improved. Judge PR-only items from their summary.
- Write one plain business sentence per change: what a user can now do or notice, and why it matters. No ticket keys, PR numbers, file paths, function, config or code terms anywhere in `## Slack` or in `## Full` above `### Internal changelog`.
- Fold chores, refactors, tests, CI, dependency bumps and docs into at most one line, "Internal improvements to reliability and maintenance.", under Improved. Leave the line out when there are none.
- Omit empty groups in both blocks. If the sources file is empty, `## Slack` and `## Full` each hold the single line "No user-facing changes recorded." and there is no `### Internal changelog`.
- Internal changelog: one line per ticket or PR. A ticket link is `<site>/browse/<KEY>`, where `<site>` is the stored `confluence_url` text before `/wiki`. Without a stored url, write the plain key.
- `## Full` uses only `###` headings. 5c-7 takes the stakeholder section from `## Full` down to `### Internal changelog`.
- Slack block: mrkdwn `*bold*` and `•` bullets, with no `#` headings and no links.
- Never write markdown checkbox lines (jc-mcp drops them).

## 5c-5. Confirm (`MODE=notes-only` only)

Print the `## Slack` and `## Full` blocks as a preview.

**Headless:** under `N1_HEADLESS=1`, do not ask. Apply `<N1_ROOT>/skills/n1-start/procedures/autonomy-headless.md § Headless Guard`. This prompt is the release confirmation gate, which is on the stop list, so it escalates and never auto-resolves. Nothing is published: set `CONF=skipped:not confirmed (headless)` and `BODY=not updated (not confirmed)`, skip 5c-6 and 5c-7, and go to 5c-8.

Otherwise ask the user once:

```
Publish these release notes for <TAG>?
1 — Yes (Recommended): publish to Confluence and update the GitHub Release body. 02-confirm-execute.md gates the same writes with one confirmation, and this flag exists to refresh published notes.
2 — Write the local file only
```

On 2: set `CONF=skipped:declined` and `BODY=not updated (declined)`, skip 5c-6 and 5c-7, and go to 5c-8.

## 5c-6. Publish to Confluence (jc-mcp only)

**1. Gate and config backfill.** The backfill only adds keys that are missing:

```bash
source ~/.n1/preamble.sh
KB=$(n1_config_val '.kb.enabled'); SID=$(n1_config_val '.kb.spaceId'); SKEY=$(n1_config_val '.kb.spaceKey')
if [ "$(n1_config_val '.tracker.type')" != "jira" ] || [ -z "$(n1_config_val '.tracker.mcp')" ] \
   || [ "$(n1_config_val '.tracker.operations.createArticle')" != "jcm_createArticle" ]; then
  echo "conf:skipped:provider not supported"
elif [ -z "$KB" ] || { [ -z "$SID" ] && [ -z "$SKEY" ]; }; then
  echo "conf:skipped:kb not configured"
elif [ "$KB" != "true" ]; then
  echo "conf:skipped:kb disabled"
else
  jq '.tracker.operations = ({"searchArticles":"jcm_searchArticles","getArticle":"jcm_getArticle","lookupSpace":"jcm_lookupSpace"} + .tracker.operations)' \
    "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json"
  echo "conf:go mcp=$(n1_config_val '.tracker.mcp') spaceId=$SID spaceKey=$SKEY"
fi
```

On `conf:skipped:<reason>`: print "Confluence publishing skipped: <reason>". Set `CONF=skipped:<reason>` and go to 5c-7.

Below, every call is `mcp__<tracker.mcp>__<operations.X>`. A thrown error, an `ok:false` result or a missing `id` warns, sets `CONF=failed:<warning>`, and goes to 5c-7.

**2. Space id.** When `spaceId` is empty, call `operations.lookupSpace` with `{spaceKey}` and persist the returned `id`. A throw or an empty id gives `CONF=skipped:space lookup failed`.

```bash
source ~/.n1/preamble.sh
ID="<id from lookupSpace>"
if [[ "$ID" =~ ^[0-9]+$ ]]; then
  jq --arg id "$ID" '.kb.spaceId = $id' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json" && echo "kb.spaceId saved: $ID"
else echo "space lookup failed"; fi
```

**3. Stored page.** If 5c-4 found `confluence_page_id:`, call `operations.getArticle` with `{pageId}`. If that succeeds, this is an update: go to 6. If it throws (the page was deleted), drop the stored id and continue with 4.

**4. Space key and parent page.** CQL strings escape `\` as `\\` and `"` as `\"` inside quoted titles.
- With `spaceKey` set: call `operations.searchArticles` with `{cql: 'space = "<spaceKey>" AND title = "Release notes" AND type = page', maxResults: 5}`. A hit whose `title` is exactly `Release notes` gives `PARENT_ID`.
- Without `spaceKey` (only `spaceId`): search results carry `spaceKey`, not `spaceId`. Call `operations.searchArticles` with `{cql: 'title = "Release notes" AND type = page', maxResults: 25}`. For each exact-title hit, call `operations.getArticle` and keep the first one whose `spaceId` equals the configured `spaceId`. That hit gives `PARENT_ID`, and its `spaceKey` becomes `spaceKey`.
- No parent found: call `operations.createArticle` with `{spaceId, title: "Release notes", body: "Stakeholder release notes, one child page per release."}` and no `parentId`. The result's `id` is `PARENT_ID`. If `spaceKey` is still unknown, take it from the result's `url` (the segment after `/spaces/`).
- A newly learned `spaceKey` is persisted. If it is still unknown, set `CONF=skipped:space key missing` and go to 5c-7.

```bash
source ~/.n1/preamble.sh
KEY="<space key>"
if [[ "$KEY" =~ ^[A-Za-z0-9_~-]+$ ]]; then
  jq --arg k "$KEY" '.kb.spaceKey = $k' "$N1_HOME/config.json" > "$N1_HOME/config.json.tmp" && mv "$N1_HOME/config.json.tmp" "$N1_HOME/config.json" && echo "kb.spaceKey saved: $KEY"
else echo "space key missing"; fi
```

**5. Existing child page.** Call `operations.searchArticles` with `{cql: 'space = "<spaceKey>" AND title = "<TITLE>" AND type = page', maxResults: 5}`. A hit whose `title` equals `TITLE` exactly gives `PAGE_ID`, and this becomes an update. CQL indexing can lag, which is why the stored page id (step 3) is checked first.

**6. Create or update.** The page body is the `## Full` block, passed verbatim:

```bash
source ~/.n1/preamble.sh
awk '/^## Full$/{f=1; next} /^## /{f=0} f' "$N1_HOME/releases/<TAG>.md"
```

- Create: call `operations.createArticle` with `{spaceId, title: TITLE, body, parentId: PARENT_ID}`. The result is `{id, title, url}`. Set `CONF=created <url>`.
- Update: call `operations.getArticle` with `{pageId}` and read `version`. Then call `operations.updateArticle` with `{pageId, title: TITLE, body, version}`, passing the **current version from getArticle** unchanged, because jc-mcp increments it itself. The result `{ok, id, version}` has no url. Set `CONF=updated <stored url>`, or `CONF=updated <TITLE> (page <id>)` when no url is stored.

**7. Store the page.** Write the url and page id back into the notes file, replacing any old lines:

```bash
source ~/.n1/preamble.sh
F="$N1_HOME/releases/<TAG>.md"; URL="<created url, or the stored url, or empty>"; PID="<page id>"
if [[ "$PID" =~ ^[0-9]+$ ]]; then
  awk -v u="$URL" -v p="$PID" '/^confluence_(url|page_id): /{next} {print} NR==1{if (u != "") print "confluence_url: " u; print "confluence_page_id: " p}' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
fi
```

## 5c-7. GitHub Release body

The stakeholder section goes above the marker `<!-- n1:release-notes:end -->`. When the notes file has a `confluence_url:` line, a link line follows the section. The GitHub-generated notes below the marker are never altered. `gh release edit --notes-file` replaces the whole body, so the snippet rebuilds it: on the first run it prepends to the old body, and on later runs it replaces everything above the first marker line. An unchanged body is not edited.

```bash
source ~/.n1/preamble.sh
TAG="<TAG>"
MARK='<!-- n1:release-notes:end -->'
S="$N1_HOME/scratch"; F="$N1_HOME/releases/$TAG.md"
mkdir -p "$S"
# Stakeholder section = the part of "## Full" above "### Internal changelog", outer blank lines trimmed.
awk '/^## Full$/{f=1; next} /^### Internal changelog$/ || /^## /{f=0} f' "$F" 2>/dev/null \
  | awk '{a[NR]=$0} NF{if (!s) s=NR; e=NR} END{for (i=s; i && i<=e; i++) print a[i]}' > "$S/release-notes-stakeholder.md"
URL=$(sed -n 's/^confluence_url: //p' "$F" 2>/dev/null | tr -d '\r' | head -1)
if [ ! -s "$S/release-notes-stakeholder.md" ]; then echo "body:no-notes"
elif ! gh release view "$TAG" --json body --jq .body > "$S/release-body-old.raw" 2>/dev/null; then echo "body:no-release"
else
  tr -d '\r' < "$S/release-body-old.raw" > "$S/release-body-old.md"
  HAS=0; grep -qxF -- "$MARK" "$S/release-body-old.md" && HAS=1
  # Kept part: everything after the first marker line, or the whole body when there is no marker; leading blank lines dropped.
  awk -v m="$MARK" -v has="$HAS" 'BEGIN{f=!has} f && !s && !NF {next} f {s=1; print; next} $0 == m {f=1}' "$S/release-body-old.md" > "$S/release-body-below.md"
  {
    cat "$S/release-notes-stakeholder.md"; echo
    [ -n "$URL" ] && printf 'Full release notes: %s\n\n' "$URL"
    echo "$MARK"
    [ -s "$S/release-body-below.md" ] && { echo; cat "$S/release-body-below.md"; }
  } > "$S/release-body-new.md"
  if cmp -s "$S/release-body-old.md" "$S/release-body-new.md"; then echo "body:unchanged"
  elif gh release edit "$TAG" --notes-file "$S/release-body-new.md" >/dev/null 2>&1; then echo "body:updated"
  else echo "body:edit-failed"; fi
fi
```

Outcomes, recorded as `BODY` for the report:
- `body:updated` gives `BODY=body updated`.
- `body:unchanged` gives `BODY=body unchanged`.
- `body:no-release` gives `BODY=not updated (no GitHub Release for <TAG>)`.
- `body:no-notes` gives `BODY=not updated (no notes file)`.
- `body:edit-failed`: warn "Could not update the GitHub Release body for <TAG>: gh release edit failed -- continuing." and set `BODY=not updated (edit failed)`.

Release deploy workflows trigger on `types: [published]`, so a body edit does not re-run a deploy. A re-trigger would show up in the Step 8 deploy watch.

## 5c-8. Report

`NOTES` = `<absolute path of $N1_HOME/releases/<TAG>.md> -- <outcome>`. The outcome is the created or stored Confluence url; `updated <TITLE> (page <id>)`; `Confluence skipped: <reason>`; or `Confluence failed: <warning>`.

Print the Slack block with:

```bash
source ~/.n1/preamble.sh
awk '/^## Slack$/{f=1; next} /^## /{f=0} f' "$N1_HOME/releases/<TAG>.md"
```

- `MODE=normal`: keep `NOTES` for the Step 9 `Release notes:` line, and continue with `04-report.md`. Step 9 prints the Slack block.
- `MODE=notes-only`: print this report, then STOP. There is no deploy watch.
  ```
  Release notes for <TAG> refreshed

  Release notes:  <NOTES>
  GitHub Release: <BODY>

  Slack-ready notes:
  <Slack block>
  ```

Idempotent: a re-run overwrites the notes file, updates the same Confluence page (found by the stored page id first, then by exact title), and replaces only the section above the marker in the GitHub Release body.
