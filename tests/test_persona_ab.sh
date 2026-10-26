#!/usr/bin/env bash
# tests/test_persona_ab.sh — runs the persona A/B eval unit suite (no claude calls).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
python3 -m unittest tests.test_persona_ab -v
