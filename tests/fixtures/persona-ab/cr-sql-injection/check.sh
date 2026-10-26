#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md cites db.py:6 (SQL built with %).
cd "$1" || exit 1
git diff --quiet HEAD && grep -qE 'db\.py:6([^0-9]|$)' findings.md
