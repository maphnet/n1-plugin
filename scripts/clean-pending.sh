#!/usr/bin/env bash
# scripts/clean-pending.sh — N1-277 one-off: strip stale awaiting-merge markers from finished overviews, i.e.
# overview.md files with a `## Finish` section that still carry frontmatter `awaiting:` (shape B) or a `## Pending`
# section (shape A). Overviews without `## Finish` (still pending) are never touched.
# Dry-run by default: show the list to the user and re-run with --apply only after they confirm.
# Edits via n1_pending_clear (lib/frontmatter.sh). Local files only: no gh, tracker or network calls.
# Usage: scripts/clean-pending.sh [--apply] [<memory-root>...]   (default roots: ~/.n1/*/memory)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/frontmatter.sh"
APPLY=0
[ "${1:-}" = --apply ] && { APPLY=1; shift; }
for a in "$@"; do case "$a" in -*) echo "usage: $0 [--apply] [<memory-root>...]" >&2; exit 2 ;; esac; done
[ $# -gt 0 ] || set -- "$HOME"/.n1/*/memory
n=0; rc=0
for root in "$@"; do
    for ov in "$root"/*/overview.md; do
        [ -f "$ov" ] || continue
        [ -r "$ov" ] || { echo "skipped (unreadable): $ov" >&2; continue; }
        shape=$(awk 'NR == 1 && /^---\r?$/ { fm = 1; next } fm && /^---\r?$/ { fm = 0; next }
            fm && /^awaiting:/ { b = 1 } /^## Finish\r?$/ { f = 1 } /^## Pending\r?$/ { a = 1 }
            END { if (f && (a || b)) print (a && b ? "A+B" : a ? "A" : "B") }' "$ov")
        [ -n "$shape" ] || continue
        if [ "$APPLY" = 1 ]; then
            if n1_pending_clear "$ov"; then echo "cleaned: $ov ($shape)"; n=$((n + 1)); else echo "failed: $ov" >&2; rc=1; fi
        else
            echo "would clean: $ov ($shape)"; n=$((n + 1))
        fi
    done
done
if [ "$APPLY" = 1 ]; then echo "$n overview(s) cleaned"; else echo "$n overview(s) would be cleaned; re-run with --apply to edit"; fi
exit "$rc"
