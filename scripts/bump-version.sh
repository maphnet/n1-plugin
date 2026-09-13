#!/usr/bin/env bash
# Usage: scripts/bump-version.sh <new-version>
# Sets the same version in all four plugin manifests (Claude Code + Codex).
set -euo pipefail
NEW="${1:?usage: bump-version.sh <new-version>}"
case "$NEW" in *.*.*) ;; *) echo "version must be MAJOR.MINOR.PATCH" >&2; exit 1 ;; esac
cd "$(dirname "$0")/.."
set_version() { # <file> <jq-path>
    jq --arg v "$NEW" "$2 = \$v" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
set_version .claude-plugin/plugin.json '.version'
set_version .claude-plugin/marketplace.json '.plugins[0].version'
set_version plugin.json '.version'
set_version .agents/plugins/marketplace.json '.plugins[0].version'
echo "version set to $NEW in 4 manifests"
