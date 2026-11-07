#!/usr/bin/env bash
# tests/test_pending_marker.sh — N1-277: awaiting-merge marker helpers (lib/frontmatter.sh n1_pending_clear /
# n1_pending_touch), n1-finish Step 6 wiring, scripts/clean-pending.sh one-off. Run: bash tests/test_pending_marker.sh
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$R/lib/frontmatter.sh"
PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }
yn() { "$@" && echo yes || echo no; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
HOOK='^awaiting: merge$'   # the exact pattern hooks/session-start.sh scans for
U=https://github.com/o/r/pull/7
OLD=2026-01-01T00:00:00Z
# The ## Pending block skills/n1-start/steps/pr.md writes.
pend() { printf '## Pending\nawaiting: merge\npr: 7\npr_url: %s\nbranch: feat\nlast_checked: %s\ncreated: %s\n' "$U" "$OLD" "$OLD"; }

# --- n1_pending_clear (merged path) ---
# C1: shape A (pr.md section) with a Finish that already carries pr_url.
A="$T/a.md"; { printf -- '---\nstep: done\n---\n# X-1\n'; pend; printf '\n## Finish\n- **Merged:** abc\npr_url: %s\n## Decision Ledger\n| a | b |\n' "$U"; } > "$A"
n1_pending_clear "$A"; eq "C1: rc 0" 0 $?
eq "C1: no Pending heading" no "$(yn grep -q '^## Pending' "$A")"
eq "C1: hook pattern no match" no "$(yn grep -q "$HOOK" "$A")"
eq "C1: pr_url once (Finish copy)" 1 "$(grep -c '^pr_url:' "$A")"
eq "C1: Finish once" 1 "$(grep -cx '## Finish' "$A")"
eq "C1: Ledger kept" yes "$(yn grep -qx '| a | b |' "$A")"
eq "C1: step kept" done "$(n1_read_frontmatter "$A" step)"
cp "$A" "$T/a1"; n1_pending_clear "$A"
eq "C1: idempotent" yes "$(yn cmp -s "$A" "$T/a1")"

# C2: shape B (frontmatter marker), no section. Only the awaiting key goes; pr/pr_url stay (readers need them).
B="$T/b.md"; printf -- '---\nstep: done\npr: 7\npr_url: %s\nawaiting: merge\nlast_checked: %s\n---\n# X-2\n## Finish\n- **Merged:** abc\n' "$U" "$OLD" > "$B"
n1_pending_clear "$B"
eq "C2: no awaiting line" no "$(yn grep -q '^awaiting:' "$B")"
eq "C2: first line still ---" '---' "$(head -1 "$B")"
eq "C2: pr_url kept" "$U" "$(n1_read_frontmatter "$B" pr_url)"
eq "C2: pr kept" 7 "$(n1_read_frontmatter "$B" pr)"
eq "C2: step kept" done "$(n1_read_frontmatter "$B" step)"

# C3: both shapes; Finish without pr_url (the minimal Finish n1_clean_ticket writes): the only pr_url copy and
# non-marker lines survive under ## Pending notes.
C="$T/c.md"; { printf -- '---\nstep: done\nawaiting: merge\n---\n# X-3\n'; pend; printf 'Final status: pr_created\n## Finish\n- **Cleanup:** worktree:none, branch:none\n'; } > "$C"
n1_pending_clear "$C"
eq "C3: no awaiting line" no "$(yn grep -q '^awaiting:' "$C")"
eq "C3: no ## Pending heading" no "$(yn grep -qx '## Pending' "$C")"
eq "C3: renamed heading" 1 "$(grep -cx '## Pending notes' "$C")"
eq "C3: note kept" yes "$(yn grep -qx 'Final status: pr_created' "$C")"
eq "C3: sole pr_url kept" yes "$(yn grep -qx "pr_url: $U" "$C")"
eq "C3: other marker keys dropped" 0 "$(grep -cE '^(pr|branch|last_checked|created):' "$C")"
cp "$C" "$T/c1"; n1_pending_clear "$C"
eq "C3: idempotent" yes "$(yn cmp -s "$C" "$T/c1")"

# C4: CRLF file.
D="$T/d.md"; printf -- '---\r\nstep: done\r\nawaiting: merge\r\n---\r\n## Pending\r\nawaiting: merge\r\npr: 7\r\n## Finish\r\npr_url: u\r\n' > "$D"
n1_pending_clear "$D"
eq "C4: CRLF no awaiting" no "$(yn grep -q '^awaiting:' "$D")"
eq "C4: CRLF no Pending heading" 0 "$(grep -c $'^## Pending\r$' "$D")"
eq "C4: CRLF Finish kept" 1 "$(grep -c $'^## Finish\r$' "$D")"

# C5: unrelated "## Pending Tracker Actions" heading untouched.
E="$T/e.md"; printf -- '---\nstep: done\n---\n## Pending Tracker Actions\n- move X-9\n## Finish\n- **Merged:** abc\n' > "$E"; cp "$E" "$T/e0"
n1_pending_clear "$E"
eq "C5: other Pending* heading untouched" yes "$(yn cmp -s "$E" "$T/e0")"

# C6: missing file is a no-op; a file without frontmatter still loses the marker section.
n1_pending_clear "$T/none.md"; eq "C6: missing file rc 0" 0 $?
eq "C6: missing file not created" no "$(yn test -e "$T/none.md")"
F="$T/f.md"; printf '# X-6\n## Pending\nawaiting: merge\n## Finish\n- **Merged:** abc\n' > "$F"
n1_pending_clear "$F"
eq "C6: no frontmatter: marker gone" no "$(yn grep -q "$HOOK" "$F")"
eq "C6: no frontmatter: Finish kept" yes "$(yn grep -qx '## Finish' "$F")"
eq "C7: no temp files left" 0 "$(ls "$T" | grep -c '\.md\.')"

# --- n1_pending_touch (timeout / no-merge path): marker stays, only step and last_checked change ---
norm() { sed -e 's/^last_checked:.*/last_checked: X/' -e 's/^step:.*/step: X/' "$1"; }
G="$T/g.md"; { printf -- '---\nstep: pr\n---\n# X-7\n'; pend; } > "$G"; cp "$G" "$T/g0"
n1_pending_touch "$G"
eq "T1: step finish" finish "$(n1_read_frontmatter "$G" step)"
eq "T1: awaiting stays" yes "$(yn grep -q "$HOOK" "$G")"
eq "T1: Pending stays" yes "$(yn grep -qx '## Pending' "$G")"
eq "T1: last_checked refreshed" no "$(yn grep -qx "last_checked: $OLD" "$G")"
eq "T1: last_checked is a UTC timestamp" yes "$(yn grep -qE '^last_checked: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$G")"
eq "T1: nothing else changed" "$(norm "$T/g0")" "$(norm "$G")"
H="$T/h.md"; printf -- '---\nstep: finish\npr: 7\npr_url: %s\nawaiting: merge\nlast_checked: %s\n---\n# X-8\n' "$U" "$OLD" > "$H"; cp "$H" "$T/h0"
n1_pending_touch "$H"
eq "T2: frontmatter awaiting stays" merge "$(n1_read_frontmatter "$H" awaiting)"
eq "T2: frontmatter last_checked refreshed" no "$(yn grep -qx "last_checked: $OLD" "$H")"
eq "T2: nothing else changed" "$(norm "$T/h0")" "$(norm "$H")"
I="$T/i.md"; printf -- '---\nstep: pr\n---\n## Pending\nawaiting: merge\n' > "$I"
n1_pending_touch "$I"
eq "T3: no last_checked key invented" 0 "$(grep -c '^last_checked:' "$I")"
eq "T3: step finish" finish "$(n1_read_frontmatter "$I" step)"
n1_pending_touch "$T/none.md"; eq "T4: missing file rc 0" 0 $?

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
