#!/usr/bin/env bash
# N1-228: on-demand n1-finish branches are reachable from their condition, never loaded at entry, and no reference path dangles.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
S=skills/n1-finish
# <step file>|<reference>|<condition (fixed string)>: the condition is on the pointer line or at most 2 lines above it.
while IFS='|' read -r step ref cond; do
  f="$S/steps/$step"; r="$S/references/$ref"
  if [ -s "$r" ]; then ok "$ref exists"; else no "$ref exists"; fi
  p=$(grep -nF "references/$ref" "$f" | head -1 | cut -d: -f1)
  c=$(grep -nF -- "$cond" "$f" | head -1 | cut -d: -f1)
  if [ -n "$p" ] && [ -n "$c" ] && [ "$c" -le "$p" ] && [ $((p - c)) -le 2 ]; then ok "$step reaches $ref under its condition"; else no "$step reaches $ref under its condition"; fi
  if grep -qF "references/$ref" "$S/SKILL.md"; then no "$ref is not read at entry"; else ok "$ref is not read at entry"; fi
done <<'EOT'
02-merge.md|merge-on-finish.md|only with `merge-on-finish:yes`
02-merge.md|local-merge.md|## Step 2b: Local Merge (no-PR path, `prMode == "skip"` only)
03-deploy.md|post-deploy-verification.md|deploy status `succeeded`
06-cleanup.md|release-routing.md|only when the entry printed `release.enabled=true`
EOT
# Every n1-finish reference path named anywhere in skill/agent/reference text exists.
for p in $(grep -rhoE 'skills/n1-finish/references/[A-Za-z0-9._-]+\.md' skills agents references | sort -u); do
  if [ -f "$p" ]; then ok "exists: $p"; else no "dangling: $p"; fi
done
[ "$FAIL" -eq 0 ]
