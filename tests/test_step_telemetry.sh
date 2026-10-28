#!/usr/bin/env bash
# N1-29: every n1-start step file emits paired n1_step_begin/n1_step_end with the
# step number from procedures/telemetry.md; no raw n1_emit_step_event remains in steps/.
# telemetry-merge.py pairs by step_number, so a missing end or a wrong number is an orphan.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEPS="$REPO_ROOT/skills/n1-start/steps"
TABLE="$REPO_ROOT/skills/n1-start/procedures/telemetry.md"
fail=0
for pair in ticket:1 analysis:2 brainstorm:3 plan:4 plan-review:5 implementation:7 qa:8 \
            review:9 fix:10 local-testing:11 pr:12 ci:13 finish:14 release:15 investigation-deliverable:16; do
    name=${pair%%:*}; num=${pair##*:}; f="$STEPS/$name.md"
    grep -qF "| $num | \`$name\` |" "$TABLE" || { echo "FAIL: telemetry.md table has no row $num $name"; fail=1; }
    for fn in n1_step_begin n1_step_end; do
        grep -qF "$fn \"$name\" $num" "$f" || { echo "FAIL: $name.md lacks $fn \"$name\" $num"; fail=1; }
    done
    bad=$(grep -oE "n1_step_(begin|end) \"$name\" [0-9]+" "$f" | grep -vE " $num\$" || true)
    [ -z "$bad" ] || { echo "FAIL: $name.md uses wrong step number: $bad"; fail=1; }
done
raw=$(grep -nF 'n1_emit_step_event' "$STEPS"/*.md || true)
[ -z "$raw" ] || { echo "FAIL: raw n1_emit_step_event in steps/ (use n1_step_begin/end):"; echo "$raw"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: all steps emit paired begin/end with table numbers"
exit "$fail"
