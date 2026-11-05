# Step 1: Gate and Scope

## 1a. Gate

```bash
source ~/.n1/preamble.sh
if [ "$(n1_config_val '.release.enabled')" = "true" ]; then echo "gate:ok"; else echo "n1-release-test requires release.enabled=true"; fi
```

On anything other than `gate:ok`, print that message and STOP. Nothing has been written.

## 1b. Refresh the default branch

```bash
source ~/.n1/preamble.sh
CURRENT=$(git branch --show-current); DEFAULT=$(n1_config_val '.git.defaultBranch')
if [ "$CURRENT" = "$DEFAULT" ]; then
  git pull --ff-only || echo "scope:stale"
else
  echo "scope:off-default $CURRENT"
fi
```

- `scope:stale`: STOP with "Could not fast-forward the `<DEFAULT>` checkout, so the test pass is stopped to avoid testing a stale checkout. Resolve it and re-run."
- `scope:off-default <branch>`: print "Scope is computed from `<branch>`, not the default branch." and count one integrity warning (`BASE_WARN=1`). Otherwise `BASE_WARN=0`.

## 1c. Previous tag and label

Run only the `VERSION` bash snippet of `<N1_ROOT>/skills/n1-release/steps/01-resolve-metadata.md` sub-step 1, with `source ~/.n1/preamble.sh` added as its first line and `echo "VERSION=$VERSION"` as its last line, and read `VERSION` from that output. Do not ask the user when it finds nothing. Paste `VERSION` below only when it matches `^[0-9A-Za-z.+-]+$` and is not `null`; otherwise paste an empty string.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
VERSION="<VERSION, or empty>"
PREV=$(n1_release_prev_tag)
# The version comes from the working tree, so before a bump merges it equals the latest tag.
if [[ "$VERSION" =~ ^[0-9A-Za-z.+-]+$ ]] && [[ "$VERSION" != *..* ]] && [ "$VERSION" != null ] && [ "v$VERSION" != "$PREV" ]; then
  LABEL="$VERSION"; FIX=yes
else
  LABEL="unreleased-$(git rev-parse --short=7 HEAD)"; FIX=no
fi
echo "PREV=$PREV LABEL=$LABEL FIX=$FIX"
```

When `FIX=no`, print "Version <VERSION> is not a new release; testing as <LABEL> and skipping the fixVersion source."

## 1d. Jira fixVersion tickets

Run this only when `FIX=yes` and `tracker.type` is `jira`. Search the tool list (load if deferred, per HOST ROUTING) for a tool whose name starts with `mcp__<tracker.mcp>__`. When none is found, warn "fixVersion source skipped: tracker server <tracker.mcp> not available" and continue.

Render the version name with the same resolution as `<N1_ROOT>/skills/n1-release/steps/03b-release-notes.md` § 5c-2 (`VERSION_NAME`). Call `mcp__<tracker.mcp>__<operations.search>` with the JQL `project = "<tracker.projectKey>" AND fixVersion = "<VERSION_NAME>"`.

An error or an empty result means the version may not exist: warn "No Jira tickets for fixVersion <VERSION_NAME>; continuing." This warning does not count as an integrity warning. Keep only keys matching `^<tracker.prefix>-[0-9]+$`.

## 1e. Ticket scope and integrity warnings

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/release.sh"
LABEL="<LABEL>"; PREV="<PREV, or empty>"; BASE_WARN="<1 when off the default branch, else 0>"
FIX_IDS="<validated fixVersion keys, space-separated, or empty>"
PREFIX=$(n1_config_val '.tracker.prefix')
DIR="$N1_HOME/releases/$LABEL"
GIT_IDS=$(n1_release_ticket_ids "$PREV" HEAD)
# Read only: pending-releases.json is reset by n1-release, never here.
PENDING=$(jq -r '.pending[].id' "$N1_HOME/pending-releases.json" 2>/dev/null | grep -E "^${PREFIX}-[0-9]+$" || true)
OTHER=$(printf '%s\n' $FIX_IDS $PENDING | grep . | sort -u)
COMMITS=$(git log "${PREV:+$PREV..}HEAD" --format='%h %s' 2>/dev/null || true)
UNTICKETED=$(grep -vE "^[0-9a-f]+ \[${PREFIX}-[0-9]+\]" <<<"$COMMITS" | grep . || true)
NOCOMMIT=$(comm -23 <(printf '%s\n' "$OTHER") <(printf '%s\n' "$GIT_IDS") | grep . || true)
IDS=$(printf '%s\n' "$GIT_IDS" "$OTHER" | grep . | sort -u)
if [ -n "$PREV" ] && ! git rev-parse --verify -q "$PREV^{commit}" >/dev/null; then
  echo "scope:error"
elif [ -z "$COMMITS" ] && [ -z "$IDS" ]; then
  echo "scope:empty"
else
  mkdir -p "$DIR"
  RANGE="${PREV:-$(git hash-object -t tree /dev/null)}..HEAD"
  { git diff --stat "$RANGE"; echo; git diff "$RANGE"; } > "$DIR/release.diff" 2>/dev/null
  [ -n "$PREV" ] || echo "warning: no previous tag, scanning the whole history"
  [ -z "$IDS" ] || sed 's/^/ticket: /' <<<"$IDS"
  [ -z "$UNTICKETED" ] || sed 's/^/warning: unticketed commit /' <<<"$UNTICKETED"
  [ -z "$NOCOMMIT" ] || sed 's/^/warning: commit-less ticket /' <<<"$NOCOMMIT"
  echo "WARN=$(( BASE_WARN + $(grep -c . <<<"$UNTICKETED") + $(grep -c . <<<"$NOCOMMIT") ))"
fi
```

On `scope:error`, print "Previous tag <PREV> does not resolve locally (fetch tags); scope not computed." and STOP. On `scope:empty`, print "Nothing to test since <PREV>." and STOP. Otherwise print the ticket list and every warning. Carry `WARN` as the integrity warning count. Every value pasted into a snippet here and in later steps must match its allow-list (`LABEL`: the 1c class, `PREV`: `^v[0-9A-Za-z.+-]+$` or empty, `BASE_WARN` and `WARN`: digits); otherwise stop instead of pasting.
