#!/usr/bin/env bash
# Pass when existing files are unchanged and findings.md cites cart.py:1 or :3 (mutable default).
cd "$1" || exit 1
git diff --quiet HEAD && grep -qE 'cart\.py:[13]([^0-9]|$)' findings.md
