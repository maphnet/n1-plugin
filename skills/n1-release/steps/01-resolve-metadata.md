# Step 1: Branch Check and Prerequisites

## Prerequisites

- `gh auth status` -- if not authenticated: "GitHub CLI is not authenticated. Run `gh auth login` first." **STOP.**

## Step 1: Branch Check

```bash
CURRENT=$(git branch --show-current)
DEFAULT=$(n1_config_val '.git.defaultBranch')
```

- **`CURRENT == DEFAULT`** -- proceed silently.
- **`CURRENT != DEFAULT`** -- ask:
  ```
  You're on branch `<CURRENT>`, not `<DEFAULT>`. Release from here?
  1 -- Yes
  2 -- No, switch to <DEFAULT> first
  ```
  If 2 -> report and STOP.

## Step 2: Resolve Release Metadata

1. **Version**: resolved via `release.versionSource` config. The value is an object `{"file": "<path>", "jq": "<expression>"}` specifying where to read the version. When `release.versionSource` is `null` or absent, auto-detect by probing common locations in order:

   ```bash
   VERSION_SOURCE=$(n1_config_val '.release.versionSource')
   if [ -z "$VERSION_SOURCE" ] || [ "$VERSION_SOURCE" = "null" ]; then
     # Auto-detect: probe common version files
     if [ -f "package.json" ]; then
       VERSION=$(jq -r '.version' package.json)
       VERSION_SOURCE_DISPLAY="package.json"
     elif [ -f ".claude-plugin/plugin.json" ]; then
       VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
       VERSION_SOURCE_DISPLAY=".claude-plugin/plugin.json"
     elif [ -f "pyproject.toml" ]; then
       VERSION=$(grep -m1 '^version' pyproject.toml | sed 's/.*= *"\(.*\)"/\1/')
       VERSION_SOURCE_DISPLAY="pyproject.toml"
     elif [ -f "Cargo.toml" ]; then
       VERSION=$(grep -m1 '^version' Cargo.toml | sed 's/.*= *"\(.*\)"/\1/')
       VERSION_SOURCE_DISPLAY="Cargo.toml"
     elif [ -f "VERSION" ]; then
       VERSION=$(cat VERSION | tr -d '[:space:]')
       VERSION_SOURCE_DISPLAY="VERSION"
     else
       VERSION=""
       VERSION_SOURCE_DISPLAY="none"
     fi
   else
     # Explicit config: {"file": "...", "jq": "..."}
     VS_FILE=$(echo "$VERSION_SOURCE" | jq -r '.file')
     VS_JQ=$(echo "$VERSION_SOURCE" | jq -r '.jq // ".version"')
     if [ -f "$VS_FILE" ]; then
       VERSION=$(jq -r "$VS_JQ" "$VS_FILE")
       VERSION_SOURCE_DISPLAY="$VS_FILE"
     else
       VERSION=""
       VERSION_SOURCE_DISPLAY="$VS_FILE (not found)"
     fi
   fi
   ```

   If `VERSION` is empty or `"null"` after resolution, ask the user:
   ```
   Could not detect project version (source: <VERSION_SOURCE_DISPLAY>).
   Enter the version to release (e.g., 1.0.0):
   ```
   Read user input as `VERSION`. If user declines, STOP.

2. **TAG**: concatenate `tagPrefix + VERSION`:
   ```bash
   TAG_PREFIX=$(n1_config_val '.release.tagPrefix')
   TAG="${TAG_PREFIX}${VERSION}"
   ```
3. **Previous tag**: resolve from local git tags first, fall back to gh:
   ```bash
   PREV_TAG=$(git tag --list "${TAG_PREFIX}*" --sort=-version:refname | head -1)
   if [ -z "$PREV_TAG" ]; then
     PREV_TAG=$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
   fi
   # Show "(none — first release)" when nothing found
   ```
3b. **Suggested next version** (derived from conventional commits since `PREV_TAG`):

   ```bash
   # Scan commit messages between previous tag and HEAD for conventional commit prefixes.
   if [ -n "${PREV_TAG:-}" ]; then
       CC_LOG=$(git log "${PREV_TAG}..HEAD" --oneline 2>/dev/null || true)
   else
       CC_LOG=$(git log --oneline 2>/dev/null || true)
   fi

   # Detect bump level: major > minor > patch
   BUMP_LEVEL="patch"
   if echo "$CC_LOG" | grep -qiE '(BREAKING[[:space:]]CHANGE|^[a-z]+(\([^)]*\))?!:)'; then
       BUMP_LEVEL="major"
   elif echo "$CC_LOG" | grep -qE '^[a-f0-9]+ feat(\([^)]*\))?:'; then
       BUMP_LEVEL="minor"
   fi

   # Split VERSION into major.minor.patch components
   IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "${VERSION}"
   V_MAJOR="${V_MAJOR:-0}"; V_MINOR="${V_MINOR:-0}"; V_PATCH="${V_PATCH:-0}"

   case "$BUMP_LEVEL" in
       major) SUGGESTED_VERSION="$((V_MAJOR + 1)).0.0" ;;
       minor) SUGGESTED_VERSION="${V_MAJOR}.$((V_MINOR + 1)).0" ;;
       patch) SUGGESTED_VERSION="${V_MAJOR}.${V_MINOR}.$((V_PATCH + 1))" ;;
   esac
   ```
4. **Merge SHA**: attempt to read from `$N1_HOME/memory/<ID>/overview.md` `## Finish` section if a memory directory exists for the inferred ticket ID (parsed from branch name via `git.branchPattern`). Otherwise empty string.
5. **Pending batch**: if `$N1_HOME/pending-releases.json` exists and `.pending` is non-empty, read its ticket IDs:
   ```bash
   PENDING_IDS=$(jq -r '.pending[].id' "$N1_HOME/pending-releases.json" 2>/dev/null || true)
   PENDING_IDS_DISPLAY=$(echo "$PENDING_IDS" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
   ```
   This release covers the whole batch — include the IDs in the Step 3 confirmation summary as `Batch: <PENDING_IDS_DISPLAY>` (omit this line when `PENDING_IDS` is empty). After a successful release (Step 5 complete), post the tracker release comment (Step 6) for EACH batched ticket ID in addition to the current ticket. Then reset the file:
   ```bash
   printf '{"pending": []}\n' > "$N1_HOME/pending-releases.json"
   ```
6. **Unified ticket discovery**: build `RELEASE_TICKET_IDS` by merging four sources (deduplicated):

   **Source A — Branch name** (existing): parse current branch via `git.branchPattern` for ticket prefix. Produces `BRANCH_ID` (single ID or empty).

   **Source B — Pending batch** (existing): `PENDING_IDS` from sub-step 5 above.

   **Source C — GitHub Release notes** (new): after Step 5 creates the release, parse its body for ticket IDs:
   ```bash
   PREFIX=$(n1_config_val '.tracker.prefix')
   GH_BODY=$(gh release view "${TAG}" --json body --jq '.body' 2>/dev/null || true)
   GH_IDS=$(echo "$GH_BODY" | grep -oE "${PREFIX}-[0-9]+" | sort -u)
   ```

   **Source D — Git log between tags** (new): scan commit messages between previous and current tag:
   ```bash
   if [ -n "$PREV_TAG" ]; then
     GIT_LOG=$(git log "${PREV_TAG}..${TAG}" --oneline 2>/dev/null || true)
   else
     GIT_LOG=$(git log "${TAG}" --oneline 2>/dev/null || true)
   fi
   GIT_IDS=$(echo "$GIT_LOG" | grep -oE "${PREFIX}-[0-9]+" | sort -u)
   ```

   **Merge all sources:**
   ```bash
   RELEASE_TICKET_IDS=$(echo -e "${BRANCH_ID}\n${PENDING_IDS}\n${GH_IDS}\n${GIT_IDS}" | grep -v '^$' | sort -u)
   ```

   Note: Sources C and D require `TAG` to exist, so their extraction runs after Step 5 (Execute) completes. The merge produces the final `RELEASE_TICKET_IDS` used by Steps 5b, 6, and 7.
