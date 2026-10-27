#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md has a defect-keyword line citing cart.py:1 or :3 (mutable default).
cd "$1" || exit 1
git diff --quiet HEAD && grep -iE 'cart\.py:[13]([^0-9]|$)' findings.md | grep -iE 'mutable|default' | grep -viE 'no (defects?|issues?|bugs?)' | grep -q .
