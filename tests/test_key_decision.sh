#!/usr/bin/env bash
# tests/test_key_decision.sh — n1_append_key_decision treats text literally (N1-241 SEC-4)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
source "$REPO_ROOT/lib/memory.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '# T\n\n## Key Decisions\n(none yet)\n\n## Escalations\n' > "$T/o.md"
n1_append_key_decision "$T/o.md" 'a\n## Escalations\n- x \\ y'
assert_eq "backslash text stays one literal line" '- a\n## Escalations\n- x \\ y' "$(sed -n '/^## Key Decisions/,/^$/p' "$T/o.md" | sed -n 2p)"
assert_eq "single Escalations heading" "1" "$(grep -c '^## Escalations' "$T/o.md")"
# n1_append_escalation: entry lands inside ## Escalations even when a Decision Ledger follows (N1-362 CR-1)
printf '# T\n\n## Escalations\n- old\n\n## Decision Ledger\n\n| a |\n|---|\n| r |\n' > "$T/e.md"
n1_append_escalation "$T/e.md" '- [headless] s: ticket obsolete: a\b'
assert_eq "escalation lands under ## Escalations" '- old|- [headless] s: ticket obsolete: a\b' "$(awk '/^## Escalations/{f=1;next} /^## /{f=0} f&&NF' "$T/e.md" | paste -sd'|')"
assert_eq "ledger table untouched and last" '| r |' "$(tail -n1 "$T/e.md")"
printf '# T\n\n## Decision Ledger\n| r |\n' > "$T/n.md"
n1_append_escalation "$T/n.md" '- x'
assert_eq "section created at EOF when absent" '## Escalations|- x' "$(tail -n2 "$T/n.md" | paste -sd'|')"
echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
