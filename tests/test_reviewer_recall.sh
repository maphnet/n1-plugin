#!/usr/bin/env bash
# tests/test_reviewer_recall.sh — runs the reviewer recall unit suite (fake claude, no paid calls).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest tests.test_reviewer_recall -v
