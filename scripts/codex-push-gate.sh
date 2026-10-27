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
# Trusts the origin host: compares owner/name only. Uses the push URL (pushurl/pushInsteadOf applied).
URL=$(git remote get-url --push origin 2>/dev/null) || blocked gate-unavailable
URL=${URL%/}; URL=${URL%.git}; URL=${URL//:/\/}
ORIGIN_REPO=$(printf '%s' "$URL" | awk -F/ '{print tolower($(NF-1) "/" $NF)}')
[ "$ORIGIN_REPO" = "$(printf '%s' "$PR_REPO" | tr 'A-Z' 'a-z')" ] || blocked gate-unavailable
LOGP=$(git -c core.quotePath=false log --no-renames --name-only --format= "$START"..HEAD 2>/dev/null) || blocked gate-unavailable
DIFFP=$(git -c core.quotePath=false diff --no-renames --name-only "$START" HEAD 2>/dev/null) || blocked gate-unavailable
# Net-added regular (100644) files only: symlinks and executables never qualify as siblings.
ADDED=$(git -c core.quotePath=false diff --no-renames --diff-filter=A --raw "$START" HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^:000000 100644 / {print $2}') || blocked gate-unavailable
ALLOWED_DIRS=$(sed -n 's|/[^/]*$||p' "$ALLOWED_FILE" | sort -u)
CHANGED=$(printf '%s\n%s\n' "$LOGP" "$DIFFP" | sed '/^$/d' | sort -u)
[ -n "$CHANGED" ] || { echo "push:none"; exit 0; }
# Deny first; then allowed.txt; then a new file in the exact dir of an allowed path (never root, never a dot component).
BAD=$(while IFS= read -r p; do
  grep -qE '^\.github/|\.gitlab-ci|Jenkinsfile|\.circleci/|azure-pipelines|(^|/)\.env|credentials|\.pem$' <<<"$p" && { printf '%s\n' "$p"; continue; }
  grep -qxF -- "$p" "$ALLOWED_FILE" && continue
  [[ $p == */* && /$p != */.* ]] && grep -qxF -- "$p" <<<"$ADDED" && grep -qxF -- "${p%/*}" <<<"$ALLOWED_DIRS" && continue
  printf '%s\n' "$p"
done <<<"$CHANGED")
[ -z "$BAD" ] || blocked "$(sort -u <<<"$BAD" | tr '\n' ' ' | sed 's/ $//')"
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=
[ -z "${GIT_SSH_COMMAND:-}${GIT_SSH:-}$(git config --get core.sshCommand 2>/dev/null)" ] && export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
if timeout -k 5 "${N1_CODEX_PUSH_TIMEOUT:-90}" git push origin HEAD:"$HEAD_REF" >/dev/null 2>&1; then echo "push:ok"; else echo "push:rejected"; fi
