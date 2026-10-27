#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md has a defect-keyword line citing paginate.py:4 (slice drops last item).
cd "$1" || exit 1
git diff --quiet HEAD && grep -iE 'paginate\.py:4([^0-9]|$)' findings.md | grep -iE 'off.by.one|slice|last|drop' | grep -viE 'no (defects?|issues?|bugs?)' | grep -q .
