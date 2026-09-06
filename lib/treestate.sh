#!/usr/bin/env bash
# lib/treestate.sh — working-tree snapshot for review freeze verification.

_n1_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
    else md5sum | cut -d' ' -f1; fi
}

# n1_tree_snapshot [<repo_dir>] → "<head>|<status-hash>"
n1_tree_snapshot() {
    local dir="${1:-.}"
    local head status_hash
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "no-head")
    status_hash=$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null | _n1_sha256)
    printf '%s|%s' "$head" "$status_hash"
}

# n1_tree_verify <snapshot> [<repo_dir>] → 0 when identical
n1_tree_verify() {
    local expected="$1" dir="${2:-.}"
    [ "$(n1_tree_snapshot "$dir")" = "$expected" ]
}

# n1_tree_is_clean [<repo_dir>] → 0 when no tracked or untracked changes
n1_tree_is_clean() {
    local dir="${1:-.}"
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)" ]
}
