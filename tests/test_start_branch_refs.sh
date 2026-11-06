#!/usr/bin/env bash
# N1-232: on-demand n1-start branches are reachable from their condition, never loaded at entry, and no procedure path dangles.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
S=skills/n1-start
# <parent under skills/n1-start>|<file under procedures/>|<condition (fixed string)>: the condition is on the pointer line or at most 2 lines above it.
while IFS='|' read -r parent ref cond; do
  [ -n "$parent" ] || continue
  f="$S/$parent"; r="$S/procedures/$ref"
  if [ -s "$r" ]; then ok "$ref exists"; else no "$ref exists"; fi
  p=$(grep -nF "procedures/$ref" "$f" | head -1 | cut -d: -f1)
  c=$(grep -nF -- "$cond" "$f" | head -1 | cut -d: -f1)
  if [ -n "$p" ] && [ -n "$c" ] && [ "$c" -le "$p" ] && [ $((p - c)) -le 2 ]; then ok "$parent reaches $ref under its condition"; else no "$parent reaches $ref under its condition"; fi
  if grep -qF "procedures/$ref" "$S/SKILL.md"; then no "$ref is not read at entry"; else ok "$ref is not read at entry"; fi
done <<'EOT'
steps/local-testing.md|local-testing-run.md|**Gates passed (not skipped):**
procedures/autonomy-headless.md|autonomy-headless-predecision.md|**Plan-time pre-decision (queue children).**
procedures/autonomy-headless.md|autonomy-headless-ask.md|**`ask`** (Claude Code queue children)
steps/analysis.md|analysis-xrepo.md|If `RELATED_ENABLED=true`
steps/ticket.md|ticket-story.md|**Story/epic** (`ISSUE_TYPE=story` or `IS_STORY=true`)
steps/review.md|review-xrepo.md|If `RELATED_ENABLED=true`
steps/review.md|review-incremental.md|If `INCREMENTAL=true`
steps/review.md|review-preexisting.md|**Pre-existing**: read
EOT
# Every relative procedures/<file>.md path named in n1-start text exists (catches a mistyped pointer).
for p in $(grep -rhoE '(^|[^/A-Za-z0-9_-])procedures/[A-Za-z0-9._-]+\.md' "$S" | sed 's#^.*procedures/#procedures/#' | sort -u); do
  if [ -f "$S/$p" ]; then ok "exists: $p"; else no "dangling: $p"; fi
done
# Every full-path skills/n1-start/procedures/<file>.md citation anywhere (skills, agents, references) exists. The full path is unambiguous, so other skills' own procedures/ dirs never match.
for p in $(grep -rhoE 'skills/n1-start/procedures/[A-Za-z0-9._-]+\.md' skills agents references | sort -u); do
  if [ -f "$p" ]; then ok "exists: $p"; else no "dangling: $p"; fi
done
[ "$FAIL" -eq 0 ]
