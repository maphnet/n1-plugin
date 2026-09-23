#!/usr/bin/env bash
# Skill and agent text must stay host-neutral (references/host-routing.md). Each check greps
# skills/ and agents/ for a host-specific literal and fails on any hit.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
check() { # <label> <extended-regex>
    local hits
    hits=$(grep -rnE "$2" skills agents 2>/dev/null || true)
    if [ -n "$hits" ]; then echo "FAIL: $1"; echo "$hits" | head -20; FAIL=1; else echo "PASS: $1"; fi
}
check "plugin root literal" '\$\{CLAUDE_PLUGIN_ROOT\}'
check "AskUserQuestion literal" 'AskUserQuestion'
check "ToolSearch literal" 'ToolSearch'
check "Agent tool / subagent_type literal" 'Agent tool|subagent_type|when the Agent returns'
check "Skill tool / superpowers: prefix" 'Skill tool|superpowers:'
check "persona namespace literal" '"n1:[a-z-]+"|`n1:(solution-architect|developer|planner|implementer|qa-engineer|code-reviewer|security-reviewer|tech-writer|product-analyst|local-test-planner)`'
# NP-192: N1_ROOT is never resolved inline; snippets source the hook-maintained ~/.n1/root symlink.
check "inline N1_ROOT resolution (use: source ~/.n1/root/lib/preamble.sh)" 'N1_ROOT="\$\{CLAUDE_PLUGIN_ROOT|source "\$N1_ROOT/lib/preamble\.sh"'

# Every fenced bash block that uses $N1_ROOT or the preamble must start with the preamble
# (each snippet is its own fresh shell).
python3 - <<'PY' || FAIL=1
import re, sys, pathlib
PRE = 'source ~/.n1/root/lib/preamble.sh'
bad = []
for path in list(pathlib.Path("skills").rglob("*.md")) + list(pathlib.Path("agents").glob("*.md")):
    text = path.read_text(encoding="utf-8")
    for m in re.finditer(r"```(?:bash|sh)\n(.*?)```", text, re.S):
        body = m.group(1)
        if ("$N1_ROOT" in body or "preamble.sh" in body) and not body.lstrip().startswith(PRE):
            bad.append(f"{path}:{text[:m.start()].count(chr(10)) + 2}")
if bad:
    print("FAIL: bash snippets using $N1_ROOT/preamble without starting with: " + PRE); print("\n".join(bad)); sys.exit(1)
print("PASS: every $N1_ROOT snippet starts with " + PRE)
PY

check "headless claude -p literal" 'claude -p'
check "worktree directory literal" '\.claude/worktrees'
check "manifest version read through plugin root" 'N1_ROOT/\.claude-plugin/plugin\.json|N1_ROOT>/\.claude-plugin'

exit $FAIL
