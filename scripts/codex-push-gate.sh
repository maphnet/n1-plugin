#!/usr/bin/env bash
# Fail-closed push gate for Codex fix commits. Prints one status line, exits 0.
# Usage: bash scripts/codex-push-gate.sh START_FILE ALLOWED_FILE HEAD_REF
set -uo pipefail
START_FILE=${1:-}; ALLOWED_FILE=${2:-}; HEAD_REF=${3:-}
blocked() { echo "push:blocked paths=$1"; exit 0; }
START=$(cat "$START_FILE" 2>/dev/null) || START=""
[[ $START =~ ^[0-9a-f]{40,64}$ ]] || blocked gate-unavailable
[ -n "$START" ] && [ -s "$ALLOWED_FILE" ] && [ -n "$HEAD_REF" ] || blocked gate-unavailable
CHANGED=$(git -c core.quotePath=false diff --no-renames --name-only "$START"..HEAD 2>/dev/null) || blocked gate-unavailable
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$HEAD_REF" ] || blocked gate-unavailable
[ -n "$CHANGED" ] || { echo "push:none"; exit 0; }
BAD=$(while IFS= read -r p; do
  grep -qxF -- "$p" "$ALLOWED_FILE" && ! grep -qE '^\.github/|\.gitlab-ci|Jenkinsfile|\.circleci/|azure-pipelines|(^|/)\.env|credentials|\.pem$' <<<"$p" || printf '%s\n' "$p"
done <<<"$CHANGED")
[ -z "$BAD" ] || blocked "$(sort -u <<<"$BAD" | tr '\n' ' ' | sed 's/ $//')"
if git push origin HEAD:"$HEAD_REF" >/dev/null 2>&1; then echo "push:ok"; else echo "push:rejected"; fi
