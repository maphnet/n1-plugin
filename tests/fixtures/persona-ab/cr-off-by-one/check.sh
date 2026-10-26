#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md cites paginate.py:4 (slice drops last item).
cd "$1" || exit 1
git diff --quiet HEAD && grep -qE 'paginate\.py:4([^0-9]|$)' findings.md
