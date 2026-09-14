<!-- Purpose: Discover and configure related N1-managed projects for cross-repo context. -->

## Related Projects Configuration

Discover and configure related projects — other N1-managed repositories that this project integrates with. This section runs after `config.json` has been written, so persistence is direct for both fresh init and `--related` re-run.

### Step 1 — Enumerate candidates

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
# Derive both candidate self-slugs (remote-URL and directory-name), each sanitized the same way.
# n1_home() resolves N1_HOME by matching whichever slug has an existing ~/.n1/<slug>/ dir,
# so we must skip a peer that matches EITHER to avoid adding self when the two slugs differ.
_rpc_url_raw=$(basename "$(git remote get-url origin 2>/dev/null)" .git 2>/dev/null || true)
_rpc_dir_raw=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)
_rpc_self_url=$(printf '%s' "$_rpc_url_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
_rpc_self_dir=$(printf '%s' "$_rpc_dir_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//')
N1_HOME=$(n1_home)
# Step 2 runs in a SEPARATE Bash invocation — persist the candidates instead of
# relying on a shell variable surviving across blocks.
CANDIDATES_FILE="$N1_HOME/cache/init-candidates.tsv"
mkdir -p "$(dirname "$CANDIDATES_FILE")"
: > "$CANDIDATES_FILE"
for peer_cfg in "${HOME}"/.n1/*/config.json; do
    [ -f "$peer_cfg" ] || continue
    peer_slug=$(basename "$(dirname "$peer_cfg")")
    # Skip self — match against both remote-URL-derived and dir-name-derived slugs
    [ "$peer_slug" = "$_rpc_self_url" ] && continue
    [ "$peer_slug" = "$_rpc_self_dir" ] && continue
    peer_repo=$(jq -r '.repoPath // empty' "$peer_cfg" 2>/dev/null)
    [ -n "$peer_repo" ] || continue
    peer_service=$(jq -r '.ticketTagging.service // empty' "$peer_cfg" 2>/dev/null)
    # A "bare registration" is a hand-authored peer config carrying only version+repoPath:
    # readable for cross-repo context, but with no tracker/ticketTagging/rules to corroborate
    # an automatic match. Such peers stay candidates but are never auto-added (see Step 2).
    peer_bare=true
    if jq -e '(.tracker // .ticketTagging // .rules) != null' "$peer_cfg" >/dev/null 2>&1; then
        peer_bare=false
    fi
    printf '%s\t%s\t%s\t%s\n' "$peer_slug" "$peer_service" "$peer_repo" "$peer_bare" >> "$CANDIDATES_FILE"
done
```

If `$CANDIDATES_FILE` is empty (all projects lack `repoPath` or only self exists), set `relatedProjects.enabled: false` silently and skip this section.

### Step 2 — Search for references (confidence cascade)

For each candidate, search the current repo for references. Classify matches by confidence:

- **High confidence** (direct import/require, shared proto path, explicit API client): auto-add with `source: "auto"`
- **Medium confidence** (env var or config reference, docker-compose dependency): read candidate's CLAUDE.md to confirm relationship before presenting
- **Low confidence** (vague name overlap, transitive): skip

Search implementation:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
source "$N1_ROOT/lib/related.sh"
N1_HOME=$(n1_home)
CANDIDATES_FILE="$N1_HOME/cache/init-candidates.tsv"
REPO_ROOT=$(git rev-parse --show-toplevel)
# The candidate snapshot is written by Step 1 in an EARLIER Bash invocation. The path is
# scoped to this project's N1_HOME and Step 1 truncates unconditionally, so cross-project
# runs cannot collide and an aborted run's leftovers are overwritten, not read. The one
# remaining window is two concurrent n1-init (or --related) runs in THIS project. No
# session identifier is available to skill Bash blocks, so warn on age instead of locking.
if [ -f "$CANDIDATES_FILE" ]; then
    _cand_mtime=$(stat -c %Y "$CANDIDATES_FILE" 2>/dev/null || stat -f %m "$CANDIDATES_FILE" 2>/dev/null || echo 0)
    _cand_age=$(( $(date +%s) - _cand_mtime ))
    if [ "$_cand_mtime" -gt 0 ] && [ "$_cand_age" -gt 30 ]; then
        echo "WARN: candidate list was generated ${_cand_age}s ago; if another n1-init run is active in this project the results may be stale — re-run Step 1 to refresh."
    fi
fi
FOUND=""
while IFS=$'\t' read -r c_slug c_service c_repo c_bare; do
    [ -z "$c_slug" ] && continue
    note=""
    # Escape ERE metacharacters and wrap with non-alphanumeric boundaries so short
    # slugs (loop, api, web) do not match unrelated code. Mirrors lib/related.sh:113-116.
    # `names` is the reusable escaped alternation; the boundary wrapper is per-site.
    names=$(n1_related_escape_ere "$c_slug")
    [ -n "$c_service" ] && names="${names}|$(n1_related_escape_ere "$c_service")"
    pattern="(^|[^a-zA-Z0-9])(${names})([^a-zA-Z0-9]|\$)"
    # Search in source files (exclude node_modules, .git, vendor)
    matches=$(grep -rlE "$pattern" "$REPO_ROOT" \
        --include='*.ts' --include='*.js' --include='*.py' --include='*.go' \
        --include='*.java' --include='*.rs' --include='*.yaml' --include='*.yml' \
        --include='*.json' --include='*.toml' --include='*.proto' \
        --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=vendor \
        2>/dev/null | head -3)
    if [ -n "$matches" ]; then
        match_summary=$(echo "$matches" | head -1 | sed "s|$REPO_ROOT/||")
        # Classify confidence based on match file type and content
        confidence="medium"
        if echo "$matches" | grep -qE '\.(proto|graphql)$'; then
            confidence="high"
        else
            _hi=0
            while IFS= read -r _f; do
                [ -n "$_f" ] || continue
                # Use the escaped alternation, not the boundary-wrapped `pattern` —
                # the wrapper cannot be nested verbatim inside this larger regex.
                # The import/require keyword prefix supplies the left-hand context.
                if grep -qE "^[[:space:]]*(import|from|require|use)\b.*(${names})" "$_f" 2>/dev/null; then _hi=1; break; fi
            done <<< "$matches"
            if [ "$_hi" = "1" ]; then
                confidence="high"
            elif echo "$matches" | grep -qE '\.(yaml|yml|env)' 2>/dev/null; then
                confidence="medium"
            fi
        fi
        # A bare registration has no tracker/CLAUDE.md context to corroborate the match,
        # so it is never auto-added: cap it at medium and route it to the confirm prompt.
        if [ "$c_bare" = "true" ] && [ "$confidence" = "high" ]; then
            confidence="medium"
            note="bare registration"
        fi
        FOUND="${FOUND}${c_slug}\t${c_service}\t${match_summary}\t${confidence}\t${note}\n"
    fi
done < "$CANDIDATES_FILE"

# Print the results — Step 3 runs in a later Bash/model turn and reads them from here.
printf '%b' "$FOUND"
```

### Step 3 — Present to user

High-confidence matches are auto-added (with `source: "auto"`). Medium-confidence matches are presented for confirmation. Low-confidence matches are skipped.

The 5th `FOUND` field is a note. When it reads `bare registration`, the peer's config holds only `version` + `repoPath` — there is no tracker or `ticketTagging` context to corroborate the match, so the row was capped at medium and must be confirmed by the user even if the match itself looked high-confidence. Show the reason in the prompt so the user understands why it is flagged.

If any medium-confidence references need confirmation:

```
Detected potential related projects:
1. **<slug>** (<service>) — referenced in <match_summary> [confidence: high, auto-added]
2. **<slug>** (<service>) — referenced in <match_summary> [confidence: medium, confirm?]
3. **<slug>** (<service>) — referenced in <match_summary> [confidence: medium, confirm? — bare registration]

Add all / Select individually / Skip?
```

For "Add all": add each with `source: "auto"` and a reason derived from the match.
For "Select individually": present each and let the user confirm/edit reason.
For "Skip": set `relatedProjects.enabled: false`.

If no references found, ask:

```
No cross-repo references detected automatically.
Do you want to manually specify related projects? (List N1 project slugs, or skip)
```

### Step 4 — Persist

`config.json` already exists at this point (written by `## Write Configuration and Structure`). Resolve `N1_HOME`, source `lib/related.sh`, call `n1_related_add` for each approved project, then update `enabled` — all in one block:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
CFG="$N1_HOME/config.json"
source "$N1_ROOT/lib/related.sh"
# For each approved project (auto-added high-confidence or user-confirmed medium-confidence):
n1_related_add "$CFG" "$slug" "$reason" "$source"
# source = "auto" for high-confidence auto-added; "manual" for user-confirmed
# n1_related_add is idempotent (skips if slug already present) and stamps confirmedAt
count=$(jq '.relatedProjects.projects | length' "$CFG")
enabled=$( [ "$count" -gt 0 ] && echo true || echo false )
jq --argjson e "$enabled" '.relatedProjects.enabled = $e' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
rm -f "$N1_HOME/cache/init-candidates.tsv"
```

If no projects were approved, `relatedProjects.enabled` remains `false` (the default seeded by the template).
