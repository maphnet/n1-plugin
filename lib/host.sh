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
    # Hook manifests set N1_HOST explicitly. Shared discovery files and config
    # locations are not evidence of which concurrent session is calling us.
    case "${N1_HOST:-}" in codex|claude-code) printf '%s' "$N1_HOST"; return;; esac
    if [ -n "${CODEX_THREAD_ID:-}" ] || [ -n "${PLUGIN_DATA:-}" ]; then printf 'codex'; return; fi
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf 'claude-code'; return; fi
    printf 'unknown'
}

n1_session_id() { printf '%s' "${N1_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}}"; }

n1_session_file() {
    local id; id=$(n1_session_id)
    case "$id" in ''|*[!a-zA-Z0-9_-]*) return 1;; esac
    printf '%s/sessions/%s.json' "${N1_STATE_DIR:-$HOME/.n1}" "$id"
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
    case "$(n1_host)" in
        codex) printf '.codex/worktrees';;
        claude-code) printf '.claude/worktrees';;
        *) echo 'N1: unknown host; set run identity before workspace routing' >&2; return 1;;
    esac
}

n1_headless_cmd() {
    # Usage: n1_headless_cmd <skill> <args> <model> <outfile> [repo] [effort] [brief-file]
    # A transport only: the caller supplies the already-selected workflow/brief.
    local skill="$1" args="$2" model="$3" out="$4" repo="${5:-}" effort="${6:-}" brief="${7:-}"
    local host prompt; host=$(n1_host)
    local cmd=()
    case "$host" in
        codex)
            cmd=(codex exec)
            [ -z "$repo" ] || cmd+=(--cd "$repo")
            [ -z "$model" ] || cmd+=(-m "$model")
            [ -z "$effort" ] || cmd+=(-c "model_reasoning_effort=\"$effort\"")
            cmd+=(--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust)
            prompt="\$$skill $args"
            ;;
        claude-code)
            cmd=(claude -p)
            prompt="/n1:$skill $args"
            ;;
        *) echo 'N1: cannot dispatch with unknown host' >&2; return 1;;
    esac
    if [ -n "$brief" ]; then
        [ -r "$brief" ] || { echo 'N1: dispatch brief is unreadable' >&2; return 1; }
        prompt+=$'\n'; prompt+="$(< "$brief")"
    fi
    cmd+=("$prompt")
    if [ "$host" = claude-code ]; then
        [ -z "$model" ] || cmd+=(--model "$model")
        [ -z "$effort" ] || cmd+=(--effort "$effort")
        cmd+=(--permission-mode bypassPermissions --output-format stream-json --verbose)
        [ -z "${N1_STORY_PLUGIN_DIR:-}" ] || cmd+=(--plugin-dir "$N1_STORY_PLUGIN_DIR")
        [ -z "$repo" ] || printf 'cd %q && ' "$repo"
    fi
    # A headless child is a new session. Retain parent linkage, never inherit its
    # run/session identity. Native child discovery is separate from this edge.
    printf 'env -u N1_SESSION_ID -u N1_RUN_ID -u N1_TRANSCRIPT_PATH -u CODEX_THREAD_ID -u CODEX_SESSION_ID -u CLAUDE_CODE_SESSION_ID N1_HOST=%q N1_PARENT_SESSION_ID=%q ' "$host" "$(n1_session_id)"
    printf '%q ' "${cmd[@]}"
    printf '> %q 2>&1' "$out"
}

n1_bg_launch_cmd() {
    # Usage: n1_bg_launch_cmd <name> <skill> <args> <model> <repo> <settings-json>
    # Claude Code background session (queue children). The session supervisor, not
    # this shell, owns the session env, so N1 vars travel inside <settings-json>.
    # The command's stdout carries "backgrounded · <id> · <name>".
    local name="$1" skill="$2" args="$3" model="$4" repo="$5" settings="$6"
    local cmd=(claude --bg --name "$name")
    [ -z "$model" ] || cmd+=(--model "$model")
    cmd+=(--permission-mode bypassPermissions --settings "$settings")
    [ -z "${N1_STORY_PLUGIN_DIR:-}" ] || cmd+=(--plugin-dir "$N1_STORY_PLUGIN_DIR")
    cmd+=("/n1:$skill $args")
    printf 'cd %q && ' "$repo"
    printf '%q ' "${cmd[@]}"
}

n1_bg_cmd() {
    # Usage: n1_bg_cmd agents | stop <id> | attach <id> — background-session control (Claude Code).
    case "$1" in
        agents) printf 'claude agents --json --all' ;;
        stop|attach) printf 'claude %s %q' "$1" "$2" ;;
        *) return 1 ;;
    esac
}

n1_desktop_notify() {
    # Usage: n1_desktop_notify <title> <body> — first desktop notifier that actually runs wins
    # (on PATH is not enough: WSL interop can be present but disabled). Returns 1 if none works.
    local t="$1" b="$2"
    if command -v notify-send >/dev/null 2>&1 && timeout 10 notify-send "$t" "$b" >/dev/null 2>&1; then return 0; fi
    if command -v osascript >/dev/null 2>&1 && timeout 10 osascript \
        -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
        "$t" "$b" >/dev/null 2>&1; then return 0; fi
    if command -v powershell.exe >/dev/null 2>&1 && N1_NT="$t" N1_NB="$b" WSLENV="N1_NT:N1_NB${WSLENV:+:$WSLENV}" \
        timeout 10 powershell.exe -NoProfile -NonInteractive -Command '
            [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
            $x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            $n = $x.GetElementsByTagName("text")
            $n.Item(0).AppendChild($x.CreateTextNode($env:N1_NT)) > $null
            $n.Item(1).AppendChild($x.CreateTextNode($env:N1_NB)) > $null
            $app = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))
        ' >/dev/null 2>&1; then return 0; fi
    return 1
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
    case "$(n1_host)" in
        codex) printf 'n1-%s' "$1";;
        claude-code) printf 'n1:%s' "$1";;
        *) echo 'N1: unknown host; cannot select persona adapter' >&2; return 1;;
    esac
}

n1_persona_name() {
    # Usage: n1_persona_name <agent_type> — persona name, or empty when not an N1 persona
    case "$1" in
        n1:*) printf '%s' "${1#n1:}" ;;
        n1-*) printf '%s' "${1#n1-}" ;;
        *) printf '' ;;
    esac
}
