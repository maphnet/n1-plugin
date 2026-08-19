#!/usr/bin/env bash
# Tests scripts/audit-orchestrator.py against a synthetic transcript.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/session.jsonl"

# Minimal synthetic transcript: n1-start invocation, an Agent spawn, then a
# main-thread pytest run and an Edit on a project file (both violations), and
# a sidechain Edit (must be ignored).
cat > "$FIX" <<'EOF'
{"type":"user","message":{"role":"user","content":"<command-name>/n1:n1-start</command-name>"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"n1:qa-engineer","description":"QA"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /work/repo && python -m pytest tests/ -q"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/work/repo/src/app.py","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/work/repo/src/side.py","old_string":"a","new_string":"b"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/home/u/.n1/proj/memory/X-1/overview.md"}}]}}
EOF

OUT="$(python3 "$REPO_ROOT/scripts/audit-orchestrator.py" "$FIX")"
PASS=0; FAIL=0
check() { if echo "$OUT" | grep -qF -- "$2"; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected: $2)"; echo "$OUT"; FAIL=$((FAIL+1)); fi; }
ncheck() { if echo "$OUT" | grep -qF -- "$2"; then echo "FAIL: $1 (unexpected: $2)"; echo "$OUT"; FAIL=$((FAIL+1)); else echo "PASS: $1"; PASS=$((PASS+1)); fi; }

check  "reports agent context"          "after AGENT n1:qa-engineer"
check  "flags pytest in main thread"    "!! B  cd /work/repo && python -m pytest"
check  "flags Edit on project file"     "!! W  /work/repo/src/app.py"
ncheck "ignores sidechain Edit"         "/work/repo/src/side.py"
ncheck "ignores .n1 memory reads"       "overview.md"
check  "prints violation total"         "violations: 2"

echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
