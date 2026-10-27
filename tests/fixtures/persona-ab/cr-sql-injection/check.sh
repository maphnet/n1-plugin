#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md has a defect-keyword line citing db.py:6 (SQL built with %).
cd "$1" || exit 1
git diff --quiet HEAD && grep -iE 'db\.py:6([^0-9]|$)' findings.md | grep -iE 'inject|parameter|%|format' | grep -viE 'no (defects?|issues?|bugs?)' | grep -q .
