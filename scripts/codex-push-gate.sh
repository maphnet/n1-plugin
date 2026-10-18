#!/usr/bin/env bash
# Fail-closed push gate for Codex fix commits. Prints one status line, exits 0.
# Usage: bash scripts/codex-push-gate.sh START_FILE ALLOWED_FILE HEAD_REF REPO_FILE
set -uo pipefail
START_FILE=${1:-}; ALLOWED_FILE=${2:-}; HEAD_REF=${3:-}; REPO_FILE=${4:-}
blocked() { echo "push:blocked paths=$1"; exit 0; }
START=$(cat "$START_FILE" 2>/dev/null) || START=""
[[ $START =~ ^[0-9a-f]{40,64}$ ]] || blocked gate-unavailable
[ -n "$START" ] && [ -s "$ALLOWED_FILE" ] && [ -n "$HEAD_REF" ] || blocked gate-unavailable
git merge-base --is-ancestor "$START" HEAD 2>/dev/null || blocked gate-unavailable
[ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$HEAD_REF" ] || blocked gate-unavailable
PR_REPO=$(cat "$REPO_FILE" 2>/dev/null) || PR_REPO=""
[ -n "$PR_REPO" ] || blocked gate-unavailable
[ "$PR_REPO" != fork ] || blocked fork-pr
URL=$(git remote get-url origin 2>/dev/null) || blocked gate-unavailable
URL=${URL%/}; URL=${URL%.git}; URL=${URL//:/\/}
ORIGIN_REPO=$(printf '%s' "$URL" | awk -F/ '{print tolower($(NF-1) "/" $NF)}')
[ "$ORIGIN_REPO" = "$(printf '%s' "$PR_REPO" | tr 'A-Z' 'a-z')" ] || blocked gate-unavailable
CHANGED=$(git -c core.quotePath=false log --no-renames --name-only --format= "$START"..HEAD 2>/dev/null | sort -u; exit "${PIPESTATUS[0]}") || blocked gate-unavailable
[ -n "$CHANGED" ] || { echo "push:none"; exit 0; }
BAD=$(while IFS= read -r p; do
  grep -qxF -- "$p" "$ALLOWED_FILE" && ! grep -qE '^\.github/|\.gitlab-ci|Jenkinsfile|\.circleci/|azure-pipelines|(^|/)\.env|credentials|\.pem$' <<<"$p" || printf '%s\n' "$p"
done <<<"$CHANGED")
[ -z "$BAD" ] || blocked "$(sort -u <<<"$BAD" | tr '\n' ' ' | sed 's/ $//')"
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"
if timeout -k 5 "${N1_CODEX_PUSH_TIMEOUT:-120}" git push origin HEAD:"$HEAD_REF" >/dev/null 2>&1; then echo "push:ok"; else echo "push:rejected"; fi
