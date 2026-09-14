#!/usr/bin/env bash
# N1 host abstraction: which agent harness runs N1 (Claude Code or Codex) and how to reach it.
# Sourced by lib/config.sh and by every hook. Pure bash; jq optional.
# Facts recorded by hooks/session-start.sh land in ~/.n1/host.json so skill snippets
# (which cannot expand ${CLAUDE_PLUGIN_ROOT} on Codex) can find the plugin root.

n1_host_file() { printf '%s' "${N1_HOST_FILE:-$HOME/.n1/host.json}"; }

_n1_host_json_get() {
    # Usage: _n1_host_json_get <key> — string field from host.json, or empty
    local f; f=$(n1_host_file)
    [ -f "$f" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$1" '.[$k] // empty' "$f" 2>/dev/null || true
    else
        grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$f" | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' || true
    fi
}

n1_host() {
    # Order: N1_HOST env; Codex when Codex-only env is present, or host.json says codex and no
    # Claude root is set (hook processes on both hosts receive CLAUDE_PLUGIN_ROOT); else Claude.
    if [ -n "${N1_HOST:-}" ]; then printf '%s' "$N1_HOST"; return; fi
    if [ -n "${PLUGIN_DATA:-}" ] || [ -n "${CODEX_HOME:-}" ]; then printf 'codex'; return; fi
    if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "$(_n1_host_json_get host)" = "codex" ]; then printf 'codex'; return; fi
    printf 'claude-code'
}

n1_plugin_root() {
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s' "$CLAUDE_PLUGIN_ROOT"; return; fi
    if [ -n "${PLUGIN_ROOT:-}" ]; then printf '%s' "$PLUGIN_ROOT"; return; fi
    local r; r=$(_n1_host_json_get pluginRoot)
    if [ -n "$r" ] && [ -d "$r" ]; then printf '%s' "$r"; return; fi
    printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

n1_plugin_version() {
    local root manifest; root=$(n1_plugin_root)
    manifest="$root/.claude-plugin/plugin.json"
    if [ "$(n1_host)" = "codex" ] && [ -f "$root/plugin.json" ]; then manifest="$root/plugin.json"; fi
    [ -f "$manifest" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.version // empty' "$manifest" 2>/dev/null || true
    else
        grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true
    fi
}

n1_worktree_root() {
    # Relative directory under the main checkout holding N1 worktrees.
    local v=""
    if type n1_config_val >/dev/null 2>&1; then v=$(n1_config_val '.worktree.root' 2>/dev/null || true); fi
    if [ -n "$v" ]; then printf '%s' "${v%/}"; return; fi
    if [ "$(n1_host)" = "codex" ]; then printf '.codex/worktrees'; else printf '.claude/worktrees'; fi
}

n1_headless_cmd() {
    # Usage: n1_headless_cmd <skill> <args> <model> <outfile> [repo]
    # Prints the shell command for a non-interactive child run of an N1 skill on the current host.
    local skill="$1" args="$2" model="$3" out="$4" repo="${5:-}"
    if [ "$(n1_host)" = "codex" ]; then
        local cd_flag="" model_flag=""
        [ -n "$repo" ] && cd_flag=" --cd \"${repo}\""
        [ -n "$model" ] && model_flag=" -c model=\"${model}\""
        # Single quotes: the prompt starts with $ and must reach codex unexpanded.
        printf "codex exec%s%s --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust '\$%s %s' > \"%s\" 2>&1" \
            "$cd_flag" "$model_flag" "$skill" "$args" "$out"
    else
        local model_flag="" plugin_dir=""
        [ -n "$model" ] && model_flag=" --model ${model}"
        [ -n "${N1_STORY_PLUGIN_DIR:-}" ] && plugin_dir=" --plugin-dir \"${N1_STORY_PLUGIN_DIR}\""
        printf 'claude -p "/n1:%s %s"%s --permission-mode bypassPermissions --output-format stream-json --verbose%s > "%s" 2>&1' \
            "$skill" "$args" "$model_flag" "$plugin_dir" "$out"
    fi
}

n1_hook_field() {
    # Usage: printf '%s' "$PAYLOAD" | n1_hook_field <name> — top-level string field or empty.
    # Field names are identical on both hosts, so one path serves both.
    local name="$1" input; input=$(cat)
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$input" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null || true
    else
        printf '%s' "$input" | grep -o "^{[^{]*\"$name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | grep -o "\"$name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"$" | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' || true
    fi
}

n1_agent_type() {
    # Usage: n1_agent_type <persona> — host-specific agent_type for an N1 persona
    if [ "$(n1_host)" = "codex" ]; then printf 'n1-%s' "$1"; else printf 'n1:%s' "$1"; fi
}

n1_persona_name() {
    # Usage: n1_persona_name <agent_type> — persona name, or empty when not an N1 persona
    case "$1" in
        n1:*) printf '%s' "${1#n1:}" ;;
        n1-*) printf '%s' "${1#n1-}" ;;
        *) printf '' ;;
    esac
}
