#!/usr/bin/env bash
# tests/test_agent_profiles.sh — runs the Codex persona TOML generator suite.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
python3 -m unittest tests.test_agent_profiles -v
