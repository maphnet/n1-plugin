#!/usr/bin/env bash
# tests/test_benchmark.sh — runs the benchmark unit suite.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest tests.test_benchmark -v
