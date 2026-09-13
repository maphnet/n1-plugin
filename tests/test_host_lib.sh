#!/usr/bin/env bash
# Tests for lib/host.sh: host detection order, plugin root fallback, worktree root, headless command.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
assert_contains() { case "$3" in *"$2"*) echo "PASS: $1"; PASS=$((PASS+1));; *) echo "FAIL: $1 (missing=[$2] in=[$3])"; FAIL=$((FAIL+1));; esac; }
assert_not_contains() { case "$3" in *"$2"*) echo "FAIL: $1 (unexpected=[$2] in=[$3])"; FAIL=$((FAIL+1));; *) echo "PASS: $1"; PASS=$((PASS+1));; esac; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_HOST PLUGIN_DATA PLUGIN_ROOT CODEX_HOME CLAUDE_PLUGIN_ROOT N1_STORY_PLUGIN_DIR N1_HOME
export N1_HOST_FILE="$T/host.json"
source "$REPO_ROOT/lib/config.sh"   # sources lib/host.sh

# --- detection order
assert_eq "default is claude-code" "claude-code" "$(n1_host)"
assert_eq "N1_HOST env wins" "codex" "$(N1_HOST=codex n1_host)"
assert_eq "PLUGIN_DATA implies codex" "codex" "$(PLUGIN_DATA=/x n1_host)"
assert_eq "CODEX_HOME implies codex" "codex" "$(CODEX_HOME=/x n1_host)"
printf '{"host":"codex","pluginRoot":"%s","version":"9.9.9"}\n' "$REPO_ROOT" > "$N1_HOST_FILE"
assert_eq "host.json codex when no CLAUDE_PLUGIN_ROOT" "codex" "$(n1_host)"
assert_eq "host.json ignored when CLAUDE_PLUGIN_ROOT set" "claude-code" "$(CLAUDE_PLUGIN_ROOT=/y n1_host)"

# --- plugin root
assert_eq "root from CLAUDE_PLUGIN_ROOT" "/y" "$(CLAUDE_PLUGIN_ROOT=/y n1_plugin_root)"
assert_eq "root from PLUGIN_ROOT" "/z" "$(PLUGIN_ROOT=/z n1_plugin_root)"
assert_eq "root from host.json" "$REPO_ROOT" "$(n1_plugin_root)"
printf '{"host":"claude-code","pluginRoot":"/nonexistent/dir"}\n' > "$N1_HOST_FILE"
assert_eq "root falls back to BASH_SOURCE parent when host.json path missing" "$REPO_ROOT" "$(n1_plugin_root)"
rm -f "$N1_HOST_FILE"

# --- version
CLAUDE_VER=$(jq -r .version "$REPO_ROOT/.claude-plugin/plugin.json")
assert_eq "version read from claude manifest" "$CLAUDE_VER" "$(N1_HOST=claude-code CLAUDE_PLUGIN_ROOT="$REPO_ROOT" n1_plugin_version)"

# --- persona namespace
assert_eq "agent type claude" "n1:developer" "$(N1_HOST=claude-code n1_agent_type developer)"
assert_eq "agent type codex" "n1-developer" "$(N1_HOST=codex n1_agent_type developer)"
assert_eq "persona from n1:" "qa-engineer" "$(n1_persona_name n1:qa-engineer)"
assert_eq "persona from n1-" "qa-engineer" "$(n1_persona_name n1-qa-engineer)"
assert_eq "persona empty for foreign type" "" "$(n1_persona_name general-purpose)"

# --- hook field
assert_eq "hook field top-level" "compact" "$(printf '{"source":"compact","tool_input":{"source":"x"}}' | n1_hook_field source)"
assert_eq "hook field missing is empty" "" "$(printf '{"a":1}' | n1_hook_field source)"

# --- worktree root
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"; echo '{}' > "$N1_HOME/config.json"
assert_eq "worktree root claude" ".claude/worktrees" "$(N1_HOST=claude-code n1_worktree_root)"
assert_eq "worktree root codex" ".codex/worktrees" "$(N1_HOST=codex n1_worktree_root)"
echo '{"worktree":{"root":".wt/"}}' > "$N1_HOME/config.json"
assert_eq "worktree root from config, trailing slash stripped" ".wt" "$(N1_HOST=codex n1_worktree_root)"

# --- headless command
CMD=$(N1_HOST=claude-code n1_headless_cmd n1-start NP-1 opus /tmp/o.jsonl)
assert_contains "claude cmd shape" 'claude -p "/n1:n1-start NP-1" --model opus --permission-mode bypassPermissions --output-format stream-json --verbose > "/tmp/o.jsonl" 2>&1' "$CMD"
CMD=$(N1_HOST=claude-code N1_STORY_PLUGIN_DIR=/dev/n1 n1_headless_cmd n1-start NP-1 opus /tmp/o.jsonl)
assert_contains "claude cmd plugin-dir" '--plugin-dir "/dev/n1"' "$CMD"
CMD=$(N1_HOST=claude-code n1_headless_cmd n1-finish NP-1 "" /tmp/o.jsonl)
assert_not_contains "claude cmd omits empty model" '--model' "$CMD"
CMD=$(N1_HOST=codex n1_headless_cmd n1-start NP-1 gpt-5.6 /tmp/o.jsonl /repo)
assert_contains "codex cmd shape" "codex exec --cd \"/repo\" -c model=\"gpt-5.6\" --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust '\$n1-start NP-1' > \"/tmp/o.jsonl\" 2>&1" "$CMD"
CMD=$(N1_HOST=codex n1_headless_cmd n1-finish NP-1 "" /tmp/o.jsonl)
assert_not_contains "codex cmd omits empty model" '-c model' "$CMD"
assert_not_contains "codex cmd omits --cd without repo" '--cd' "$CMD"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
