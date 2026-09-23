# Procedure: Cross-Repo

## §5b Runtime Cross-Repo Detection

Gate: `relatedProjects.enabled=true`. Scan implementation diff.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/related.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"; XREPO_RT_ADDED_FILE="$N1_HOME/memory/$ID/xrepo-runtime-added"
rm -f "$XREPO_RT_FILE" "$XREPO_RT_ADDED_FILE"
if [ "$RELATED_ENABLED" = "true" ]; then
    IMPL_DIFF=$(git diff "$(n1_config_val '.git.defaultBranch' "$N1_HOME/config.json")"...HEAD 2>/dev/null || true)
    if [ -n "$IMPL_DIFF" ]; then DETECTED=$(n1_related_detect_in_diff "$IMPL_DIFF" "$N1_HOME/config.json"); fi
    if [ -n "$DETECTED" ]; then
        printf '%s\n' "$DETECTED" > "$XREPO_RT_FILE"; AUTONOMY=$(n1_autonomy_val "mechanicalPrompts"); IMPL_XREPO_DETECTED=""
        while IFS=$'\t' read -r det_slug det_signal; do
            [ -z "$det_slug" ] && continue; det_cell=$(printf '%s' "$det_signal" | tr '|' '/' | cut -c1-80)
            if [ "$AUTONOMY" = "auto" ]; then
                n1_related_add "$N1_HOME/config.json" "$det_slug" "auto-detected: $det_signal" "auto"
                grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
                printf '| implementation | scope | B | [auto] | New integration %s in diff | Added | — | Auto-detected: %s | --- |\n' "$det_slug" "$det_cell" >> "$N1_HOME/memory/$ID/overview.md"
                printf '%s\n' "$det_slug" >> "$XREPO_RT_ADDED_FILE"
            else IMPL_XREPO_DETECTED="${IMPL_XREPO_DETECTED:+$IMPL_XREPO_DETECTED\n}- **${det_slug}**: ${det_signal}"; fi
        done < <(printf '%s\n' "$DETECTED")
        [ "$AUTONOMY" != "auto" ] && [ -n "$IMPL_XREPO_DETECTED" ] && printf '\nNew cross-repo integrations:\n%b\n\nAdd? (yes/no/select)\n' "$IMPL_XREPO_DETECTED"
    fi
fi
```

**Interactive (non-auto).** Re-read `$XREPO_RT_FILE`. **"yes":** `n1_related_add`+B-tier `[asked]` ledger+`$XREPO_RT_ADDED_FILE` per slug. **"select":** add approved+ledger. **"no":** `[asked]` row.

**Telemetry for implementation step-end:**
```bash
source ~/.n1/preamble.sh
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"; XREPO_RT_ADDED_FILE="$N1_HOME/memory/$ID/xrepo-runtime-added"
XREPO_RT_DETECTED=""; XREPO_RT_ADDED=""
[ "$RELATED_ENABLED" = "true" ] && { [ -s "$XREPO_RT_FILE" ] && XREPO_RT_DETECTED=$(awk -F'\t' 'NF {print $1}' "$XREPO_RT_FILE" | tr '\n' ',' | sed 's/,$//'); [ -s "$XREPO_RT_ADDED_FILE" ] && XREPO_RT_ADDED=$(tr '\n' ',' < "$XREPO_RT_ADDED_FILE" | sed 's/,$//');}
IMPL_XREPO_METADATA="{\"cross_repo_runtime_detected\":\"${XREPO_RT_DETECTED}\",\"cross_repo_runtime_added\":\"${XREPO_RT_ADDED}\"}"
```
Merge `$IMPL_XREPO_METADATA` into implementation step-end metadata.

## §7b Review Cross-Repo Telemetry

Gate: `relatedProjects.enabled=true`.
```bash
XREPO_FINDINGS_COUNT=$(grep -c '^\- \*\*\[XREPO-' "$N1_HOME/memory/$ID/review.md" 2>/dev/null | head -1); XREPO_FINDINGS_COUNT="${XREPO_FINDINGS_COUNT:-0}"
```
