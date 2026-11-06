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
    XR_BASE=$(n1_story_base) || { echo "ERROR: invalid story base" >&2; exit 1; }; XR_BASE="${XR_BASE:+origin/$XR_BASE}"
    IMPL_DIFF=$(git diff "${XR_BASE:-$(n1_config_val '.git.defaultBranch' "$N1_HOME/config.json")}"...HEAD 2>/dev/null || true)
    if [ -n "$IMPL_DIFF" ]; then DETECTED=$(n1_related_detect_in_diff "$IMPL_DIFF" "$N1_HOME/config.json"); fi
    if [ -n "$DETECTED" ]; then
        printf '%s\n' "$DETECTED" > "$XREPO_RT_FILE"
        while IFS=$'\t' read -r det_slug det_signal; do
            [ -z "$det_slug" ] && continue; det_cell=$(printf '%s' "$det_signal" | tr '|' '/' | cut -c1-80)
            n1_related_add "$N1_HOME/config.json" "$det_slug" "auto-detected: $det_signal" "auto"
            grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null || printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
            printf '| implementation | scope | B | [auto] | New integration %s in diff | Added | — | Auto-detected: %s | --- |\n' "$det_slug" "$det_cell" >> "$N1_HOME/memory/$ID/overview.md"
            printf '%s\n' "$det_slug" >> "$XREPO_RT_ADDED_FILE"
        done < <(printf '%s\n' "$DETECTED")
    fi
fi
```
