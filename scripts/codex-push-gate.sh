#!/usr/bin/env bash
# Fail-closed push gate for Codex fix commits. Prints one status line, exits 0.
# Usage: bash scripts/codex-push-gate.sh START_FILE ALLOWED_FILE HEAD_REF REPO_FILE [PATCH_FILE]
# With PATCH_FILE, a path-blocked or rejected fix is saved there (git diff --binary START HEAD, mode 600; not saved when a denylisted path matched) and the
# branch is reset --keep to START: the status line gains " reset=<old tip>", or " kept=<tip>" if not safe.
set -uo pipefail
START_FILE=${1:-}; ALLOWED_FILE=${2:-}; HEAD_REF=${3:-}; REPO_FILE=${4:-}; PATCH_FILE=${5:-}
blocked() { echo "push:blocked paths=$1"; exit 0; }
recover() { # <status line> [remote]: with "remote", reset only if origin is known not to hold the tip
  local tip r; tip=$(git rev-parse HEAD 2>/dev/null)
  if [ -n "${2:-}" ]; then
    r=$(timeout -k 5 20 git ls-remote "$(git remote get-url --push origin 2>/dev/null)" "refs/heads/$HEAD_REF" 2>/dev/null | cut -f1)
    [ -n "$r" ] && [ "$r" != "$tip" ] || { echo "$1 kept=$tip"; exit 0; }
    # A different remote tip may still contain the fix (push accepted, then another writer advanced it): reset only if tip is provably absent.
    timeout -k 5 20 git fetch -q "$(git remote get-url --push origin 2>/dev/null)" "refs/heads/$HEAD_REF" >/dev/null 2>&1 || { echo "$1 kept=$tip"; exit 0; }
    git merge-base --is-ancestor "$tip" FETCH_HEAD 2>/dev/null; [ $? -eq 1 ] || { echo "$1 kept=$tip"; exit 0; }
  fi
  if { (umask 077; rm -f "$PATCH_FILE"; git -c diff.noprefix=false -c diff.mnemonicPrefix=false diff --binary --no-color --no-ext-diff --no-textconv "$START" HEAD > "$PATCH_FILE"); } 2>/dev/null && [ -s "$PATCH_FILE" ] && git reset -q --keep "$START" 2>/dev/null; then
    echo "$1 reset=$tip"
  else
    echo "$1 kept=$tip"
  fi
  exit 0
}
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
# Outgoing commits that ever record a non-100644 mode (symlink/exec/gitlink/delete) for a path disqualify it as a sibling.
NONREG=$(git -c core.quotePath=false log -m --no-renames --raw --format= "$START"..HEAD 2>/dev/null | awk -F'\t' 'NF>1 {split($1,a," "); if (a[2]!="100644") print $2}') || blocked gate-unavailable
# dir/ext of allowed paths: a sibling needs a dotted name whose extension matches an allowed path in the same dir.
ALLOWED_DIR_EXTS=$(grep -E '/[^/]+\.[^/.]+$' "$ALLOWED_FILE" | sed -E 's|^(.*)/[^/]*\.([^/.]+)$|\1/\2|' | sort -u)
# Sibling-only: basenames that a loader/tool auto-reads (agent instructions, compose, package manifests, test/import hooks).
SIBDENY='(^|/)((CLAUDE|AGENTS|GEMINI)[^/]*\.md|(docker-)?compose[^/]*\.ya?ml|action\.ya?ml|(package|composer|deno)\.json|(pyproject|Cargo)\.toml|setup\.(py|cfg)|(conftest|__init__|sitecustomize|usercustomize)\.py|(tox|pytest)\.ini|[^/]*\.pth|[^/]*-lock\.(json|ya?ml)|npm-shrinkwrap\.json|[^/]*\.lock|[^/]*\.config\.[^/]+|[^/]*rc\.[^/]+|(ts|js)config[^/]*\.json)$'
# ponytail: denylist is best-effort; if it keeps growing, switch to an allowlist of safe sibling names.
DENY='^\.github/|\.gitlab-ci|Jenkinsfile|\.circleci/|azure-pipelines|(^|/)\.env|credentials|\.pem$'
CHANGED=$(printf '%s\n%s\n' "$LOGP" "$DIFFP" | sed '/^$/d' | sort -u)
[ -n "$CHANGED" ] || { echo "push:none"; exit 0; }
# Deny first; then allowed.txt; then a new file in the exact dir of an allowed path (never root, never a dot component).
BAD=$(while IFS= read -r p; do
  grep -qE "$DENY" <<<"$p" && { printf '%s\n' "$p"; continue; }
  grep -qxF -- "$p" "$ALLOWED_FILE" && continue
  [[ $p == */* && /$p != */.* ]] && grep -qxF -- "$p" <<<"$ADDED" && ! grep -qxF -- "$p" <<<"$NONREG" && [[ ${p##*/} == *.?* ]] && ! grep -qiE "$SIBDENY" <<<"$p" && grep -qxF -- "${p%/*}/${p##*.}" <<<"$ALLOWED_DIR_EXTS" && continue
  printf '%s\n' "$p"
done <<<"$CHANGED")
if [ -n "$BAD" ]; then
  S="push:blocked paths=$(sort -u <<<"$BAD" | tr '\n' ' ' | sed 's/ $//')"
  # Denylisted content (credentials, CI) is never copied into the saved patch, but the commits still leave the branch.
  if [ -n "$PATCH_FILE" ]; then
    if grep -qE "$DENY" <<<"$BAD"; then
      rm -f "$PATCH_FILE"
      tip=$(git rev-parse HEAD 2>/dev/null)
      if git reset -q --keep "$START" 2>/dev/null; then echo "$S reset=$tip"; else echo "$S kept=$tip"; fi
      exit 0
    fi
    recover "$S"
  fi
  echo "$S"; exit 0
fi
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=
[ -z "${GIT_SSH_COMMAND:-}${GIT_SSH:-}$(git config --get core.sshCommand 2>/dev/null)" ] && export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
if timeout -k 5 "${N1_CODEX_PUSH_TIMEOUT:-90}" git push origin HEAD:"$HEAD_REF" >/dev/null 2>&1; then echo "push:ok"
elif [ -n "$PATCH_FILE" ]; then recover push:rejected remote
else echo "push:rejected"; fi
