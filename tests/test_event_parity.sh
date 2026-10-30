#!/usr/bin/env bash
# N1-227 AC2: step/gate/decision event call sites in skills/n1-start are unchanged by
# transition-turn batching. The manifest was captured from main before the edit.
# --write regenerates it (only on an unmodified tree, or when an event change is intended).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$REPO_ROOT/skills/n1-start"
MANIFEST="$REPO_ROOT/tests/fixtures/event-parity.manifest"
FNS="n1_step_begin n1_step_end n1_record_decision n1_eval_signal_gate n1_review_fix_gate n1_emit_outcome n1_emit_question_event n1_append_key_decision"

manifest() {
    local rel fn n
    (cd "$SKILL" && find . -name '*.md' | LC_ALL=C sort) | while read -r rel; do
        rel=${rel#./}
        for fn in $FNS; do
            n=$(grep -owF -- "$fn" "$SKILL/$rel" | wc -l); n=$((n))
            if [ "$n" -gt 0 ]; then printf '%s\t%s\t%d\n' "$rel" "$fn" "$n"; fi
        done
    done
}

if [ "${1:-}" = "--write" ]; then
    mkdir -p "$(dirname "$MANIFEST")"; manifest > "$MANIFEST"; echo "wrote $MANIFEST"; exit 0
fi

fail=0
if [ ! -f "$MANIFEST" ]; then
    echo "FAIL: missing $MANIFEST (run --write on an unmodified main tree)"; exit 1
fi
d=$(diff -u "$MANIFEST" <(manifest)) || { echo "FAIL: event call sites changed vs main manifest:"; echo "$d"; fail=1; }

# A step file may begin only its own step: no file emits the next step's begin.
for f in "$SKILL"/steps/*.md; do
    name=$(basename "$f" .md)
    other=$(grep -oE 'n1_step_begin "[a-z-]+"' "$f" | grep -vxF "n1_step_begin \"$name\"" || true)
    [ -z "$other" ] || { echo "FAIL: $name.md begins another step: $other"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "PASS: event call sites match main manifest; each step file begins only itself"
exit "$fail"
