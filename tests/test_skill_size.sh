#!/usr/bin/env bash
# Enforces the 6 KB (6144 bytes) budget on all skill dispatchers.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
MAX_BYTES=6144

# Check directory-style skills (skills/<name>/SKILL.md)
for f in skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    size=$(wc -c < "$f")
    if [ "$size" -gt "$MAX_BYTES" ]; then
        echo "FAIL: $f is $size bytes (max $MAX_BYTES)"
        FAIL=1
    fi
done

# Check flat-file skills (skills/<name>.md) if any exist
for f in skills/*.md; do
    [ -f "$f" ] || continue
    size=$(wc -c < "$f")
    if [ "$size" -gt "$MAX_BYTES" ]; then
        echo "FAIL: $f is $size bytes (max $MAX_BYTES)"
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: all skill dispatchers under $MAX_BYTES bytes"
else
    echo "SOME SKILL FILES EXCEED SIZE BUDGET"
fi
exit $FAIL
