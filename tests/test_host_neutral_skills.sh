#!/usr/bin/env bash
# Skill and agent text must stay host-neutral (references/host-routing.md). Each check greps
# skills/ and agents/ for a host-specific literal and fails on any hit outside the allowed preamble.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
PREAMBLE='N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c '"'"'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])'"'"')'
check() { # <label> <extended-regex>
    local hits
    hits=$(grep -rnE "$2" skills agents 2>/dev/null | grep -vF "$PREAMBLE" || true)
    if [ -n "$hits" ]; then echo "FAIL: $1"; echo "$hits" | head -20; FAIL=1; else echo "PASS: $1"; fi
}
check "plugin root literal outside the preamble" '\$\{CLAUDE_PLUGIN_ROOT\}'
check "AskUserQuestion literal" 'AskUserQuestion'
check "ToolSearch literal" 'ToolSearch'
check "Agent tool / subagent_type literal" 'Agent tool|subagent_type|when the Agent returns'
check "Skill tool / superpowers: prefix" 'Skill tool|superpowers:'
check "persona namespace literal" '"n1:[a-z-]+"|`n1:(solution-architect|developer|planner|implementer|qa-engineer|code-reviewer|security-reviewer|tech-writer|product-analyst|local-test-planner)`'

# Every fenced bash block that uses $N1_ROOT must start with the preamble (each snippet is its own shell).
python3 - <<'PY' || FAIL=1
import re, sys, pathlib
OLD_PRE = 'N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -n "$N1_ROOT" ] && [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c \'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])\')'
NEW_PRE = 'source "$N1_ROOT/lib/preamble.sh"'
def has_preamble(body):
    stripped = body.lstrip()
    return stripped.startswith(OLD_PRE) or stripped.startswith(NEW_PRE)
bad = []
for path in list(pathlib.Path("skills").rglob("*.md")) + list(pathlib.Path("agents").glob("*.md")):
    text = path.read_text(encoding="utf-8")
    for m in re.finditer(r"```(?:bash|sh)\n(.*?)```", text, re.S):
        body = m.group(1)
        if "$N1_ROOT" in body and not has_preamble(body):
            bad.append(f"{path}:{text[:m.start()].count(chr(10)) + 2}")
if bad:
    print("FAIL: bash snippets using $N1_ROOT without the preamble:"); print("\n".join(bad)); sys.exit(1)
print("PASS: every $N1_ROOT snippet starts with the preamble")
PY

check "headless claude -p literal" 'claude -p'
check "worktree directory literal" '\.claude/worktrees'
check "manifest version read through plugin root" 'N1_ROOT/\.claude-plugin/plugin\.json|N1_ROOT>/\.claude-plugin'

exit $FAIL
