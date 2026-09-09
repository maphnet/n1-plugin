#!/usr/bin/env bash
# Tests for lib/related.sh helpers (cross-repo awareness).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label (expected=[$expected] actual=[$actual])"; FAIL=$((FAIL+1))
    fi
}

export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
: "${N1_HOME:=}"; : "${ID:=}"; export N1_HOME ID
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/related.sh"

# --- project_map_path --------------------------------------------------------
test_project_map_path() {
    assert_eq "map path" "/home/user/.n1/myproj/cache/project-map.md" \
        "$(n1_project_map_path "/home/user/.n1/myproj")"
}

# --- related_project_map ----------------------------------------------------
test_related_project_map() {
    local root; root=$(mktemp -d); trap 'rm -rf "$root"' RETURN
    HOME_ORIG="$HOME"; export HOME="$root"
    mkdir -p "$root/.n1/assistant/cache"
    local result
    result=$(n1_related_project_map "assistant")
    assert_eq "related map path" "$root/.n1/assistant/cache/project-map.md" "$result"
    export HOME="$HOME_ORIG"
}

test_project_map_path
test_related_project_map

# --- project_map_check_freshness ---------------------------------------------
test_check_freshness_cold() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local result
    result=$(n1_project_map_check_freshness "$tmp/nonexistent.md" "72h") || true
    assert_eq "cold: no file" "cold" "$result"
}

test_check_freshness_stale() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local map="$tmp/project-map.md"
    cat > "$map" <<'MAPEOF'
---
schema_version: 1
generated_at: 2020-01-01T00:00:00Z
git_sha: abc1234
generator: solution-architect
---

## Modules
- src/ — source
MAPEOF
    local result
    result=$(n1_project_map_check_freshness "$map" "72h") || true
    assert_eq "stale: old timestamp" "stale" "$result"
}

test_check_freshness_fresh() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local map="$tmp/project-map.md"
    local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "$map" <<MAPEOF
---
schema_version: 1
generated_at: ${now}
git_sha: abc1234
generator: solution-architect
---

## Modules
- src/ — source
MAPEOF
    local result
    result=$(n1_project_map_check_freshness "$map" "72h")
    assert_eq "fresh: recent timestamp" "fresh" "$result"
}

test_check_freshness_cold
test_check_freshness_stale
test_check_freshness_fresh

# --- related_projects --------------------------------------------------------
test_related_projects() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    # Create a config with relatedProjects
    mkdir -p "$tmp/.n1/assistant" "$tmp/.n1/ingestion"
    echo '{"repoPath":"/repos/assistant"}' > "$tmp/.n1/assistant/config.json"
    echo '{"repoPath":"/repos/ingestion"}' > "$tmp/.n1/ingestion/config.json"

    local cfg="$tmp/config.json"
    cat > "$cfg" <<'CFGEOF'
{
  "relatedProjects": {
    "enabled": true,
    "maxSnapshotAge": "72h",
    "projects": [
      {"slug": "assistant", "reason": "API provider", "source": "auto", "confirmedAt": "2026-09-09T00:00:00Z"},
      {"slug": "ingestion", "reason": "gRPC consumer", "source": "manual", "confirmedAt": "2026-09-08T00:00:00Z"},
      {"slug": "ghost", "reason": "no repoPath", "source": "manual", "confirmedAt": "2026-09-07T00:00:00Z"}
    ]
  }
}
CFGEOF

    HOME_ORIG="$HOME"; export HOME="$tmp"
    local result
    result=$(n1_related_projects "$cfg")
    local count
    count=$(echo "$result" | grep -c '.' 2>/dev/null || echo 0)
    assert_eq "related: 2 projects with repoPath" "2" "$count"
    echo "$result" | grep -q "assistant" && assert_eq "related: has assistant" "1" "1" || assert_eq "related: has assistant" "1" "0"
    echo "$result" | grep -q "ingestion" && assert_eq "related: has ingestion" "1" "1" || assert_eq "related: has ingestion" "1" "0"
    echo "$result" | grep -q "ghost" && assert_eq "related: no ghost" "0" "1" || assert_eq "related: no ghost" "0" "0"
    export HOME="$HOME_ORIG"
}

test_related_projects

# --- related_detect_in_diff --------------------------------------------------
test_detect_in_diff() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/.n1/assistant" "$tmp/.n1/ingestion"
    echo '{"ticketTagging":{"service":"Assistant"},"repoPath":"/repos/assistant"}' > "$tmp/.n1/assistant/config.json"
    echo '{"ticketTagging":{"service":"Ingestion"},"repoPath":"/repos/ingestion"}' > "$tmp/.n1/ingestion/config.json"

    local cfg="$tmp/config.json"
    cat > "$cfg" <<'CFGEOF'
{
  "relatedProjects": {
    "enabled": true,
    "projects": [
      {"slug": "assistant", "reason": "already known", "source": "auto"}
    ]
  }
}
CFGEOF

    HOME_ORIG="$HOME"; export HOME="$tmp"

    # Diff that mentions ingestion (not in relatedProjects) but not assistant (already known)
    local diff='+import { IngestClient } from "@velocity/ingestion-client";
+const INGESTION_HOST = process.env.INGESTION_HOST;'

    local result
    result=$(n1_related_detect_in_diff "$diff" "$cfg")
    echo "$result" | grep -q "ingestion" && assert_eq "detect: found ingestion" "1" "1" || assert_eq "detect: found ingestion" "1" "0"
    echo "$result" | grep -q "assistant" && assert_eq "detect: no assistant (already known)" "0" "1" || assert_eq "detect: no assistant (already known)" "0" "0"

    export HOME="$HOME_ORIG"
}

# --- related_detect_in_diff: self-exclusion ----------------------------------
test_detect_excludes_self() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/.n1/myself" "$tmp/.n1/ingestion"
    echo '{"ticketTagging":{"service":"Myself"},"repoPath":"/repos/myself"}' > "$tmp/.n1/myself/config.json"
    echo '{"ticketTagging":{"service":"Ingestion"},"repoPath":"/repos/ingestion"}' > "$tmp/.n1/ingestion/config.json"

    local cfg="$tmp/config.json"
    echo '{"relatedProjects":{"enabled":true,"projects":[]}}' > "$cfg"

    HOME_ORIG="$HOME"; export HOME="$tmp"
    N1_HOME_ORIG="${N1_HOME:-}"; export N1_HOME="$tmp/.n1/myself"

    # Diff references the current project itself AND a peer project
    local diff='+const a = require("./myself/foo");
+const b = require("./ingestion/bar");'

    local result
    result=$(n1_related_detect_in_diff "$diff" "$cfg")
    echo "$result" | grep -q "^myself	" && assert_eq "detect: self excluded (derived slug)" "0" "1" || assert_eq "detect: self excluded (derived slug)" "0" "0"
    echo "$result" | grep -q "^ingestion	" && assert_eq "detect: peer still found" "1" "1" || assert_eq "detect: peer still found" "1" "0"

    # Explicit current_slug parameter also excludes self
    result=$(n1_related_detect_in_diff "$diff" "$cfg" "myself")
    echo "$result" | grep -q "^myself	" && assert_eq "detect: self excluded (explicit slug)" "0" "1" || assert_eq "detect: self excluded (explicit slug)" "0" "0"

    export N1_HOME="$N1_HOME_ORIG"
    export HOME="$HOME_ORIG"
}

# --- related_detect_in_diff: regex safety ------------------------------------
test_detect_regex_safety() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/.n1/a.b" "$tmp/.n1/api"
    echo '{"repoPath":"/repos/ab"}' > "$tmp/.n1/a.b/config.json"
    echo '{"repoPath":"/repos/api"}' > "$tmp/.n1/api/config.json"

    local cfg="$tmp/config.json"
    echo '{"relatedProjects":{"enabled":true,"projects":[]}}' > "$cfg"

    HOME_ORIG="$HOME"; export HOME="$tmp"
    N1_HOME_ORIG="${N1_HOME:-}"; export N1_HOME="$tmp/.n1/self"

    # "axb" must not match slug "a.b"; "rapids" must not match slug "api"
    local diff='+const x = "axb";
+const y = "rapids";'
    local result
    result=$(n1_related_detect_in_diff "$diff" "$cfg")
    assert_eq "detect: no metachar/substring false positives" "" "$result"

    # Real word-boundary references are still detected
    diff='+import client from "@org/api-client";'
    result=$(n1_related_detect_in_diff "$diff" "$cfg" | awk -F'\t' '{print $1}')
    assert_eq "detect: bounded match still found" "api" "$result"

    export N1_HOME="$N1_HOME_ORIG"
    export HOME="$HOME_ORIG"
}

# --- related_detect_in_diff: quoting safety ----------------------------------
test_detect_quote_safety() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

    mkdir -p "$tmp/.n1/ingestion"
    echo '{"repoPath":"/repos/ingestion"}' > "$tmp/.n1/ingestion/config.json"

    local cfg="$tmp/config.json"
    echo '{"relatedProjects":{"enabled":true,"projects":[]}}' > "$cfg"

    HOME_ORIG="$HOME"; export HOME="$tmp"
    N1_HOME_ORIG="${N1_HOME:-}"; export N1_HOME="$tmp/.n1/self"

    # Unbalanced quote in the diff line must not truncate or error the signal
    local diff='+  const msg = "it'"'"'s the /ingestion/ route;'
    local signal
    signal=$(n1_related_detect_in_diff "$diff" "$cfg" | awk -F'\t' '{print $2}')
    assert_eq "detect: unbalanced quote preserved" 'const msg = "it'"'"'s the /ingestion/ route;' "$signal"

    export N1_HOME="$N1_HOME_ORIG"
    export HOME="$HOME_ORIG"
}

# --- related_add -------------------------------------------------------------
test_related_add() {
    local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
    local cfg="$tmp/config.json"
    echo '{"relatedProjects":{"enabled":true,"projects":[]}}' > "$cfg"

    n1_related_add "$cfg" "assistant" "API provider" "auto"
    local count
    count=$(jq '.relatedProjects.projects | length' "$cfg")
    assert_eq "add: one entry" "1" "$count"

    local slug
    slug=$(jq -r '.relatedProjects.projects[0].slug' "$cfg")
    assert_eq "add: slug correct" "assistant" "$slug"

    # Idempotent — adding same slug again should not duplicate
    n1_related_add "$cfg" "assistant" "API provider v2" "manual"
    count=$(jq '.relatedProjects.projects | length' "$cfg")
    assert_eq "add: idempotent" "1" "$count"

    # Adding different slug works
    n1_related_add "$cfg" "ingestion" "gRPC consumer" "manual"
    count=$(jq '.relatedProjects.projects | length' "$cfg")
    assert_eq "add: second entry" "2" "$count"
}

# --- related_escape_ere ------------------------------------------------------
test_escape_ere() {
    assert_eq "escape: plain slug unchanged" "loop" "$(n1_related_escape_ere "loop")"
    assert_eq "escape: hyphen and underscore unchanged" "app-legal_service" \
        "$(n1_related_escape_ere "app-legal_service")"
    assert_eq "escape: dot escaped" 'app\.core' "$(n1_related_escape_ere 'app.core')"
    assert_eq "escape: plus and parens escaped" 'a\+b\(c\)' "$(n1_related_escape_ere 'a+b(c)')"
    assert_eq "escape: brackets, backslash and alternation escaped" '\[x\]\\y\|z' \
        "$(n1_related_escape_ere '[x]\y|z')"

    # Functional guard: the boundary-wrapped pattern built from a dictionary-word
    # slug must not match an in-word occurrence, but must match a bounded one.
    local names pattern
    names=$(n1_related_escape_ere "loop")
    pattern="(^|[^a-zA-Z0-9])(${names})([^a-zA-Z0-9]|\$)"

    local got
    if printf '%s\n' "for (const x of xs) { doloopwork(x); }" | grep -qE "$pattern"; then
        got="match"
    else
        got="nomatch"
    fi
    assert_eq "escape: no in-word match for 'loop'" "nomatch" "$got"

    if printf '%s\n' "import { c } from 'loop/client';" | grep -qE "$pattern"; then
        got="match"
    else
        got="nomatch"
    fi
    assert_eq "escape: bounded match for 'loop'" "match" "$got"

    # A metacharacter-bearing name must be matched literally, not as a regex.
    names=$(n1_related_escape_ere "app.core")
    pattern="(^|[^a-zA-Z0-9])(${names})([^a-zA-Z0-9]|\$)"
    if printf '%s\n' "require('appXcore/index')" | grep -qE "$pattern"; then
        got="match"
    else
        got="nomatch"
    fi
    assert_eq "escape: dot is literal, not wildcard" "nomatch" "$got"
}

test_detect_in_diff
test_detect_excludes_self
test_detect_regex_safety
test_detect_quote_safety
test_related_add
test_escape_ere

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
