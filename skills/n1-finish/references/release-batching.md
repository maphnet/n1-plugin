# Release Batching (Report option 3)

When user picks "Batch: queue this ticket for the next release":

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
F="$N1_HOME/pending-releases.json"
[ -f "$F" ] || printf '{"pending": []}\n' > "$F"
TMP=$(jq --arg id "$ID" --arg sha "$MERGE_SHA" --arg ts "$TS" \
    '.pending += [{"id": $id, "merged_sha": $sha, "added": $ts}]' "$F")
printf '%s\n' "$TMP" > "$F"
```
