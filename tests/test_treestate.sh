#!/usr/bin/env bash
# tests/test_treestate.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
source "$REPO_ROOT/lib/treestate.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q; git -C "$T" config user.email t@t; git -C "$T" config user.name t
echo a > "$T/a.txt"; git -C "$T" add a.txt; git -C "$T" commit -qm init

S1=$(n1_tree_snapshot "$T")
n1_tree_verify "$S1" "$T" && ok "unchanged tree verifies" || ko "unchanged tree verifies"
n1_tree_is_clean "$T" && ok "clean tree detected" || ko "clean tree detected"

echo b >> "$T/a.txt"
n1_tree_verify "$S1" "$T" && ko "dirty change detected" || ok "dirty change detected"
n1_tree_is_clean "$T" && ko "dirty tree not clean" || ok "dirty tree not clean"

git -C "$T" commit -qam second
n1_tree_verify "$S1" "$T" && ko "HEAD move detected" || ok "HEAD move detected"
n1_tree_is_clean "$T" && ok "clean after commit" || ko "clean after commit"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
