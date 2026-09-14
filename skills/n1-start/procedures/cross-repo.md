# Procedure: Cross-Repo

Covers runtime cross-repo detection (post-implementation, §5b) and review cross-repo telemetry (post-review, §7b).

## §5b Runtime Cross-Repo Detection (post-implementation)

**Runtime cross-repo detection (post-implementation):**

When `relatedProjects.enabled` is `true` in config, scan the implementation diff for unregistered cross-repo references:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")

# State files — the prompt response and the telemetry merge run in LATER Bash
# invocations, where shell variables from this block no longer exist.
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"
XREPO_RT_ADDED_FILE="$N1_HOME/memory/$ID/xrepo-runtime-added"
rm -f "$XREPO_RT_FILE" "$XREPO_RT_ADDED_FILE"

if [ "$RELATED_ENABLED" = "true" ]; then
    # Get the diff since the base branch
    IMPL_DIFF=$(git diff "$(n1_config_val '.git.defaultBranch' "$N1_HOME/config.json")"...HEAD 2>/dev/null || true)

    if [ -n "$IMPL_DIFF" ]; then
        DETECTED=$(n1_related_detect_in_diff "$IMPL_DIFF" "$N1_HOME/config.json")

        if [ -n "$DETECTED" ]; then
            printf '%s\n' "$DETECTED" > "$XREPO_RT_FILE"
            AUTONOMY=$(n1_autonomy_val "mechanicalPrompts")
            IMPL_XREPO_DETECTED=""

            while IFS=$'\t' read -r det_slug det_signal; do
                [ -z "$det_slug" ] && continue
                # Ledger cells must not contain pipes and must stay short (ledger.md Rules 4-5)
                det_cell=$(printf '%s' "$det_signal" | tr '|' '/' | cut -c1-80)

                if [ "$AUTONOMY" = "auto" ]; then
                    n1_related_add "$N1_HOME/config.json" "$det_slug" "auto-detected: $det_signal" "auto"
                    if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
                        printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
                    fi
                    printf '| implementation | scope | B | [auto] | New integration with %s detected in diff | Added to related projects | — | Auto-detected from: %s | --- |\n' "$det_slug" "$det_cell" >> "$N1_HOME/memory/$ID/overview.md"
                    printf '%s\n' "$det_slug" >> "$XREPO_RT_ADDED_FILE"
                else
                    IMPL_XREPO_DETECTED="${IMPL_XREPO_DETECTED:+$IMPL_XREPO_DETECTED\n}- **${det_slug}**: ${det_signal}"
                fi
            done < <(printf '%s\n' "$DETECTED")

            if [ "$AUTONOMY" != "auto" ] && [ -n "$IMPL_XREPO_DETECTED" ]; then
                printf '\nNew cross-repo integrations detected in your changes:\n%b\n\nAdd to related projects? (yes/no/select)\n' "$IMPL_XREPO_DETECTED"
            fi
        fi
    fi
fi
```

**Interactive response handling (non-auto path):**

The user's response arrives in a NEW Bash invocation, so the detections are re-read from `$XREPO_RT_FILE` (written by the block above) rather than from shell variables.

On the user's response to "Add to related projects? (yes/no/select)":

- **"yes"** — add all detected slugs:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"
XREPO_RT_ADDED_FILE="$N1_HOME/memory/$ID/xrepo-runtime-added"

while IFS=$'\t' read -r det_slug det_signal; do
    [ -z "$det_slug" ] && continue
    n1_related_add "$N1_HOME/config.json" "$det_slug" "auto-detected: $det_signal" "manual"
    if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
        printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
    fi
    printf '| implementation | scope | B | [asked] | New integration with %s detected in diff | Added to related projects | — | User approved on prompt | codebase |\n' "$det_slug" >> "$N1_HOME/memory/$ID/overview.md"
    printf '%s\n' "$det_slug" >> "$XREPO_RT_ADDED_FILE"
done < "$XREPO_RT_FILE"
```

- **"select"** — present each detected slug from `$XREPO_RT_FILE` individually; apply `n1_related_add` + ledger row (tag `[asked]`) only for the approved ones; skip the rest (no ledger row for skipped). Append each approved slug to `$XREPO_RT_ADDED_FILE`.

- **"no"** — add nothing; append one ledger row per detected slug recording the decline:

```bash
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"
while IFS=$'\t' read -r det_slug det_signal; do
    [ -z "$det_slug" ] && continue
    if ! grep -q '^## Decision Ledger' "$N1_HOME/memory/$ID/overview.md" 2>/dev/null; then
        printf '\n## Decision Ledger\n\n| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |\n|------|----------|------|-----|----------|--------|--------------|--------|-------------|\n' >> "$N1_HOME/memory/$ID/overview.md"
    fi
    printf '| implementation | scope | B | [asked] | New integration with %s detected in diff | Not added | Added to related projects | User declined on prompt | codebase |\n' "$det_slug" >> "$N1_HOME/memory/$ID/overview.md"
done < "$XREPO_RT_FILE"
```

After handling the response, `$XREPO_RT_ADDED_FILE` holds every slug that was added (auto or interactively approved).

**Collect telemetry metadata for implementation step:**

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
RELATED_ENABLED=$(n1_config_val ".relatedProjects.enabled" "$N1_HOME/config.json")
XREPO_RT_FILE="$N1_HOME/memory/$ID/xrepo-runtime.tsv"
XREPO_RT_ADDED_FILE="$N1_HOME/memory/$ID/xrepo-runtime-added"
XREPO_RT_DETECTED=""
XREPO_RT_ADDED=""

if [ "$RELATED_ENABLED" = "true" ]; then
    [ -s "$XREPO_RT_FILE" ] && XREPO_RT_DETECTED=$(awk -F'\t' 'NF {print $1}' "$XREPO_RT_FILE" | tr '\n' ',' | sed 's/,$//')
    [ -s "$XREPO_RT_ADDED_FILE" ] && XREPO_RT_ADDED=$(tr '\n' ',' < "$XREPO_RT_ADDED_FILE" | sed 's/,$//')
fi

IMPL_XREPO_METADATA="{\"cross_repo_runtime_detected\":\"${XREPO_RT_DETECTED}\",\"cross_repo_runtime_added\":\"${XREPO_RT_ADDED}\"}"
```

When emitting the implementation step-end telemetry event (step 7, per the Telemetry Step Markers template in `procedures/telemetry.md`), merge `$IMPL_XREPO_METADATA` fields into the `metadata` JSON object alongside the standard `execution_path` field:

```json
{"execution_path":"direct|sdd","cross_repo_runtime_detected":"<slug,...>","cross_repo_runtime_added":"<slug,...>"}
```

No separate emit is added here — the implementation step's existing end event (emitted by `steps/implementation.md` or the orchestrator after that step) carries these fields. `$IMPL_XREPO_METADATA` is available in scope for that merge.

## §7b Review Cross-Repo Telemetry (post-review)

**Cross-repo telemetry (post-review):**

When `relatedProjects.enabled` is `true` in config, count `[XREPO-N]` advisory findings in the review output:

```bash
XREPO_FINDINGS_COUNT=$(grep -c '^\- \*\*\[XREPO-' "$N1_HOME/memory/$ID/review.md" 2>/dev/null | head -1)
XREPO_FINDINGS_COUNT="${XREPO_FINDINGS_COUNT:-0}"
```

When emitting the review step-end telemetry event (step 9, per the Telemetry Step Markers template in `procedures/telemetry.md`), merge `$XREPO_FINDINGS_COUNT` into the `metadata` JSON object alongside the standard fields:

```json
{"findings_total":<N>,"findings_critical":<N>,"cross_repo_xrepo_findings":<N>}
```

No separate emit is added here — the review step's existing end event carries this field when `relatedProjects.enabled` is `true`. When the feature is disabled, omit the field entirely.
