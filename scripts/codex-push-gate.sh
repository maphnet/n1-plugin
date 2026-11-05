#!/usr/bin/env bash
# Fail-closed pre-push scope gate for Codex fix commits (N1-405). Prints one status line, exits 0; never pushes.
# Usage: bash scripts/codex-push-gate.sh START_FILE ALLOWED_FILE [PATCH_FILE]
# push:none = no change since START; push:ok = every changed path is allowed (safe to push); push:blocked paths=<...>.
# With PATCH_FILE, a blocked fix is saved there (git diff --binary START HEAD, mode 600; not saved when a denylisted path matched) and the
# branch is reset --keep to START: the status line gains " reset=<old tip>", or " kept=<tip>" if not safe.
set -uo pipefail
START_FILE=${1:-}; ALLOWED_FILE=${2:-}; PATCH_FILE=${3:-}
blocked() { echo "push:blocked paths=$1"; exit 0; }
START=$(cat "$START_FILE" 2>/dev/null) || START=""
[[ $START =~ ^[0-9a-f]{40,64}$ ]] || blocked gate-unavailable
[ -s "$ALLOWED_FILE" ] || blocked gate-unavailable
git merge-base --is-ancestor "$START" HEAD 2>/dev/null || blocked gate-unavailable
LOGP=$(git -c core.quotePath=false log --no-renames --name-only --format= "$START"..HEAD 2>/dev/null) || blocked gate-unavailable
DIFFP=$(git -c core.quotePath=false diff --no-renames --name-only "$START" HEAD 2>/dev/null) || blocked gate-unavailable
# Net-added regular (100644) files only: symlinks and executables never qualify as siblings.
ADDED=$(git -c core.quotePath=false diff --no-renames --diff-filter=A --raw "$START" HEAD 2>/dev/null | awk -F'\t' '$1 ~ /^:000000 100644 / {print $2}') || blocked gate-unavailable
# Fix commits that ever record a non-100644 mode (symlink/exec/gitlink/delete) for a path disqualify it as a sibling.
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
[ -n "$BAD" ] || { echo "push:ok"; exit 0; }
S="push:blocked paths=$(sort -u <<<"$BAD" | tr '\n' ' ' | sed 's/ $//')"
[ -n "$PATCH_FILE" ] || { echo "$S"; exit 0; }
tip=$(git rev-parse HEAD 2>/dev/null)
# Denylisted content (credentials, CI) is never copied into the saved patch, but the commits still leave the branch.
if grep -qE "$DENY" <<<"$BAD"; then
  rm -f "$PATCH_FILE"
  if git reset -q --keep "$START" 2>/dev/null; then echo "$S reset=$tip"; else echo "$S kept=$tip"; fi
  exit 0
fi
if { (umask 077; rm -f "$PATCH_FILE"; git -c diff.noprefix=false -c diff.mnemonicPrefix=false diff --binary --no-color --no-ext-diff --no-textconv "$START" HEAD > "$PATCH_FILE"); } 2>/dev/null && [ -s "$PATCH_FILE" ] && git reset -q --keep "$START" 2>/dev/null; then
  echo "$S reset=$tip"
else
  echo "$S kept=$tip"
fi
