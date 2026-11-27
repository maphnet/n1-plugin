#!/usr/bin/env bash
# tests/test_release_version.sh -- N1-654: n1_release_version resolves VERSION for the git-tag, {file,jq} and
# auto-detect release.versionSource forms, and the n1-release skill text wires the git-tag source.
# Run: bash tests/test_release_version.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/n1"
expect() { if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; FAIL=1; fi; }
check() { if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

# resolve <dir> <config json>: prints "<VERSION>|<VERSION_SOURCE_DISPLAY>".
resolve() {
    echo "$2" > "$T/n1/config.json"
    (export N1_HOME="$T/n1" N1_ROOT="$PWD"; source "$PWD/lib/config.sh"; source "$PWD/lib/release.sh"
     cd "$1" && n1_release_version && printf '%s|%s\n' "$VERSION" "$VERSION_SOURCE_DISPLAY")
}

D="$T/p"; mkdir -p "$D/.claude-plugin"
printf '[project]\nname = "x"\nversion = "0.0.0"\n' > "$D/pyproject.toml"

# Bug: a placeholder pyproject version wins over the git-tag source.
GIT='{"release":{"versionSource":{"git":"tag"}}}'
expect "git-tag source ignores a 0.0.0 pyproject" "|git tag (latest v* tag)" "$(resolve "$D" "$GIT")"

# Auto-detect is unchanged: absent, empty release block, explicit null.
expect "auto-detect: absent config reads pyproject" "0.0.0|pyproject.toml" "$(resolve "$D" '{}')"
expect "auto-detect: no versionSource reads pyproject" "0.0.0|pyproject.toml" "$(resolve "$D" '{"release":{}}')"
expect "auto-detect: null versionSource reads pyproject" "0.0.0|pyproject.toml" "$(resolve "$D" '{"release":{"versionSource":null}}')"

# Probe order: package.json > plugin manifest > pyproject > Cargo.toml > VERSION.
printf '[package]\nversion = "2.0.0"\n' > "$D/Cargo.toml"; printf '3.0.0\n' > "$D/VERSION"
expect "auto-detect: pyproject beats Cargo.toml and VERSION" "0.0.0|pyproject.toml" "$(resolve "$D" '{}')"
echo '{"version":"4.0.0"}' > "$D/.claude-plugin/plugin.json"
expect "auto-detect: plugin manifest beats pyproject" "4.0.0|.claude-plugin/plugin.json" "$(resolve "$D" '{}')"
echo '{"version":"5.0.0"}' > "$D/package.json"
expect "auto-detect: package.json wins" "5.0.0|package.json" "$(resolve "$D" '{}')"
C="$T/cargo"; mkdir -p "$C"; printf '[package]\nversion = "2.0.0"\n' > "$C/Cargo.toml"
expect "auto-detect: Cargo.toml alone" "2.0.0|Cargo.toml" "$(resolve "$C" '{}')"
V="$T/vfile"; mkdir -p "$V"; printf ' 3.0.0\n' > "$V/VERSION"
expect "auto-detect: VERSION file, whitespace stripped" "3.0.0|VERSION" "$(resolve "$V" '{}')"
E="$T/empty"; mkdir -p "$E"
expect "auto-detect: nothing found" "|none" "$(resolve "$E" '{}')"

# Explicit {file,jq} is unchanged.
echo '{"app":{"version":"6.1.0"}}' > "$D/meta.json"
expect "file+jq source" "6.1.0|meta.json" "$(resolve "$D" '{"release":{"versionSource":{"file":"meta.json","jq":".app.version"}}}')"
expect "file source, default .version" "5.0.0|package.json" "$(resolve "$D" '{"release":{"versionSource":{"file":"package.json"}}}')"
expect "file source, missing file" "|nope.json (not found)" "$(resolve "$D" '{"release":{"versionSource":{"file":"nope.json"}}}')"
expect "unknown object keeps the old not-found path" "|null (not found)" "$(resolve "$D" '{"release":{"versionSource":{"git":"branch"}}}')"

# --- Skill wiring. Bugs: TAG becomes "v" with an empty git-tag version; the suggestion ignores the latest tag;
# the gate never turns the confirmed version into TAG; a retry keeps PREV_TAG equal to TAG.
R01=skills/n1-release/steps/01-resolve-metadata.md; R02=skills/n1-release/steps/02-confirm-execute.md
check "step 01 resolves the version through the helper" '^   n1_release_version$' "$R01"
check "step 01 documents the git-tag form" '\{"git": "tag"\}' "$R01"
check "TAG stays empty while VERSION is empty" 'TAG=""; \[ -n "\$VERSION" \] && TAG="v\$VERSION"' "$R01"
check "3b seeds the suggestion from PREV_TAG when VERSION is empty" 'BASE="\$\{VERSION:-\$\{PREV_TAG#v\}\}"' "$R01"
check "gate sets VERSION from the suggestion on 1 for git-tag" 'On 1, set `VERSION` to `SUGGESTED_VERSION`' "$R02"
check "gate re-resolves PREV_TAG on a git-tag retry" 'n1_release_prev_tag --exclude "\$TAG"' "$R02"

# Bug: a 4-field tag (v1.2.3.4) leaves "3.4" in V_PATCH and the patch bump fails on the arithmetic.
SNIP=$(grep -E '^   (IFS=.\..? read -r V_MAJOR|V_PATCH=|V_MAJOR=)' "$R01" | sed 's/^   //')
bump() { (BASE="$1"; eval "$SNIP"; echo "$V_MAJOR.$V_MINOR.$((V_PATCH + 1))" 2>&1); }
expect "3b patch bump of a four-field tag" "1.2.4" "$(bump 1.2.3.4)"
expect "3b patch bump of a plain tag" "1.2.4" "$(bump 1.2.3)"
expect "3b patch bump of a prerelease-suffixed tag" "1.2.4" "$(bump 1.2.3-rc1)"

exit $FAIL
