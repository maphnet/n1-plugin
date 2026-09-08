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

test_detect_in_diff
test_related_add

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
