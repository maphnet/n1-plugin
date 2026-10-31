#!/usr/bin/env bash
# N1 host helpers. Claude Code is the only host (N1-63).
# Sourced by lib/config.sh and by every hook. Pure bash; jq optional.
# Facts recorded by hooks/session-start.sh land in ~/.n1/host.json so skill snippets
# (Bash subprocesses do not receive ${CLAUDE_PLUGIN_ROOT}) can find the plugin root.

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

n1_host() { printf 'claude-code'; }

n1_session_id() { printf '%s' "${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"; }

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
    printf '.claude/worktrees'
}

n1_headless_cmd() {
    # Usage: n1_headless_cmd <skill> <args> <model> <outfile> [repo] [effort] [brief-file]
    # A transport only: the caller supplies the already-selected workflow/brief.
    local skill="$1" args="$2" model="$3" out="$4" repo="${5:-}" effort="${6:-}" brief="${7:-}"
    local prompt="/n1:$skill $args"
    local cmd=(claude -p)
    if [ -n "$brief" ]; then
        [ -r "$brief" ] || { echo 'N1: dispatch brief is unreadable' >&2; return 1; }
        prompt+=$'\n'; prompt+="$(< "$brief")"
    fi
    cmd+=("$prompt")
    [ -z "$model" ] || cmd+=(--model "$model")
    [ -z "$effort" ] || cmd+=(--effort "$effort")
    cmd+=(--permission-mode bypassPermissions --output-format stream-json --verbose)
    [ -z "${N1_STORY_PLUGIN_DIR:-}" ] || cmd+=(--plugin-dir "$N1_STORY_PLUGIN_DIR")
    [ -z "$repo" ] || printf 'cd %q && ' "$repo"
    # A headless child is a new session. Retain parent linkage, never inherit its
    # run/session identity.
    printf 'env -u N1_SESSION_ID -u N1_RUN_ID -u N1_TRANSCRIPT_PATH -u CLAUDE_CODE_SESSION_ID N1_PARENT_SESSION_ID=%q ' "$(n1_session_id)"
    printf '%q ' "${cmd[@]}"
    # Closed stdin: a headless child must never wait on an inherited pipe (NP-224).
    printf '< /dev/null > %q 2>&1' "$out"
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
    # Usage: n1_bg_cmd agents | stop <id> | attach <id> | reopen <full-session-id> | resume <full-session-id> <prompt>
    # Background-session control (Claude Code). resume (N1-55) continues a stopped session in the
    # background under the same id: full id + no other flags — passing --permission-mode/--settings/
    # --model here forks a new session id instead (verified live, N1-55 spike); the child's saved
    # launch options are restored automatically. reopen <full-session-id> resumes a stopped
    # session interactively (attach only reaches a running one).
    case "$1" in
        agents) printf 'claude agents --json --all' ;;
        stop|attach) printf 'claude %s %q' "$1" "$2" ;;
        reopen) printf 'claude --resume %q' "$2" ;;
        resume) printf 'claude --bg --resume %q %q' "$2" "$3" ;;
        *) return 1 ;;
    esac
}

n1_powershell_path() {
    # powershell.exe on PATH, else the WSL default (wsl.conf appendWindowsPath=false hides it from PATH).
    command -v powershell.exe 2>/dev/null && return 0
    local p="${N1_WSL_POWERSHELL:-/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe}"
    [ -x "$p" ] && printf '%s\n' "$p"
}

n1_desktop_notify() {
    # Usage: n1_desktop_notify <title> <body> — first desktop notifier that actually runs wins
    # (on PATH is not enough: WSL interop can be present but disabled). Returns 1 if none works.
    local t="$1" b="$2"
    if command -v notify-send >/dev/null 2>&1 && timeout 10 notify-send "$t" "$b" >/dev/null 2>&1; then return 0; fi
    if command -v osascript >/dev/null 2>&1 && timeout 10 osascript \
        -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' \
        "$t" "$b" >/dev/null 2>&1; then return 0; fi
    local ps; ps=$(n1_powershell_path)
    if [ -n "$ps" ] && N1_NT="$t" N1_NB="$b" WSLENV="N1_NT:N1_NB${WSLENV:+:$WSLENV}" \
        timeout 10 "$ps" -NoProfile -NonInteractive -Command '
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
    local name="$1" input; input=$(cat)
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$input" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null || true
    else
        printf '%s' "$input" | grep -o "^{[^{]*\"$name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | grep -o "\"$name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"$" | sed 's/.*:[[:space:]]*"\([^"]*\)"$/\1/' || true
    fi
}

n1_agent_type() { printf 'n1:%s' "$1"; }  # Usage: n1_agent_type <persona>

n1_persona_name() {
    # Usage: n1_persona_name <agent_type> — persona name, or empty when not an N1 persona
    case "$1" in
        n1:*) printf '%s' "${1#n1:}" ;;
        *) printf '' ;;
    esac
}

# ---- Orca workspace manager (N1-224) ----
# Every call goes through "$ORCA_CLI_COMMAND" (never a bare `orca`) with --json appended. When
# ORCA_CLI_COMMAND is unset every helper returns at once with zero subprocesses (AC7). Targets are
# always `path:<abs toplevel>`: `current` from an unregistered nested worktree resolves to the parent checkout.
_N1_ORCA_ACTIVE=""   # per-process cache: "" unknown, 1 active, 0 inactive

n1_orca() {
    # Usage: n1_orca <args...> — prints the CLI's JSON stdout and returns its exit code (127: no CLI).
    [ -n "${ORCA_CLI_COMMAND:-}" ] && [ -x "$ORCA_CLI_COMMAND" ] || return 127
    if command -v timeout >/dev/null 2>&1; then
        timeout "${N1_ORCA_TIMEOUT:-5}" "$ORCA_CLI_COMMAND" "$@" --json 2>/dev/null </dev/null
    else
        "$ORCA_CLI_COMMAND" "$@" --json 2>/dev/null </dev/null
    fi
}

n1_orca_active() {
    # Usage: n1_orca_active — true when the Orca runtime is reachable (jq required; no jq = inactive).
    [ -n "${ORCA_CLI_COMMAND:-}" ] || return 1
    if [ -z "$_N1_ORCA_ACTIVE" ]; then
        _N1_ORCA_ACTIVE=0
        command -v jq >/dev/null 2>&1 \
            && n1_orca status | jq -e '.result.runtime.reachable == true' >/dev/null 2>&1 \
            && _N1_ORCA_ACTIVE=1
    fi
    [ "$_N1_ORCA_ACTIVE" = 1 ]
}

n1_orca_owns() {
    # Usage: n1_orca_owns [abs-path] — true when the path (default: this checkout) is a non-main Orca worktree.
    # The single "Orca-owned" predicate for status, links and removal.
    n1_orca_active || return 1
    local p="${1:-}"
    [ -n "$p" ] || p=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    n1_orca worktree list | jq -e --arg p "$p" 'any(.result.worktrees[]?; .path == $p and .isMainWorktree != true)' >/dev/null 2>&1
}

n1_orca_display_name() {
    # Usage: n1_orca_display_name <abs-path> — displayName of that Orca worktree, or empty.
    n1_orca_active || return 0
    n1_orca worktree list | jq -r --arg p "$1" 'first(.result.worktrees[]? | select(.path == $p) | .displayName // empty) // empty' 2>/dev/null
    return 0
}

n1_orca_sync() {
    # Usage: n1_orca_sync "<step>: <state>" [--status in-progress|in-review|completed] [--unread]
    # Best-effort card update for this checkout when Orca owns it. Always returns 0.
    [ -n "${ORCA_CLI_COMMAND:-}" ] || return 0
    local c top s args
    c=$(printf '%s' "${1:-}" | tr -d '\000-\037\177'); c="${c:0:120}"
    [ $# -gt 0 ] && shift
    case "$c" in [A-Za-z0-9]*) ;; *) return 0 ;; esac   # never looks like an option
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    n1_orca_owns "$top" || return 0
    args=(worktree set --worktree "path:$top" --comment "$c")
    while [ $# -gt 0 ]; do
        case "$1" in
            --status) s="${2:-}"
                      case "$s" in in-progress|in-review|completed) args+=(--workspace-status "$s") ;; esac
                      [ $# -gt 1 ] && shift ;;
            --unread) args+=(--unread) ;;
        esac
        shift
    done
    n1_orca "${args[@]}" >/dev/null 2>&1 || true
    return 0
}

n1_orca_link() {
    # Usage: n1_orca_link <tracker-key|url> — best-effort `reference add` on this checkout's Orca worktree. Always returns 0.
    [ -n "${ORCA_CLI_COMMAND:-}" ] || return 0
    local r="${1:-}" top
    case "$r" in ""|-*|*[[:space:][:cntrl:]]*) return 0 ;; esac
    top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    n1_orca_owns "$top" || return 0
    n1_orca reference add "$r" --worktree "path:$top" >/dev/null 2>&1 || true
    return 0
}

n1_orca_rm() {
    # Usage: n1_orca_rm <abs-path> — remove an Orca-owned worktree through Orca (never --force).
    # Prints a one-line reason and returns 1 on failure. Only n1_finish_cleanup calls this;
    # the tail-worker is denied it (hooks/enforce-agent-policy.py TAIL_DENY_RE).
    local p="${1:-}" out
    case "$p" in /*) ;; *) echo "invalid path"; return 1 ;; esac
    n1_orca_owns "$p" || { echo "not a workspace-manager worktree"; return 1; }
    out=$(N1_ORCA_TIMEOUT=60 n1_orca worktree rm --worktree "path:$p") && return 0
    jq -r '.error.message // empty' <<<"$out" 2>/dev/null | head -1
    return 1
}

n1_orca_handoff() {
    # Usage: n1_orca_handoff <ID> <type|""> create|launch [abs-path]
    # Hands the run to a fresh agent in an Orca workspace. Prints exactly one line:
    #   handoff:ok <workspace-name> <agent-handle> | handoff:failed (<reason>). Always returns 0.
    # Delivered = zero exit AND an agent handle AND (when reported) prompt outcome journaled|handed-to-terminal; field paths pinned by the live check.
    local id="${1:-}" ty="${2:-}" mode="${3:-}" path="${4:-}" prompt out msg handle kind name a=()
    [[ "$id" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { echo "handoff:failed (invalid ticket id)"; return 0; }
    [ -z "$ty" ] || [[ "$ty" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo "handoff:failed (invalid type)"; return 0; }
    n1_orca_active || { echo "handoff:failed (workspace manager inactive)"; return 0; }
    prompt="/n1:n1-start $id${ty:+ --type $ty} --no-handoff"
    case "$mode" in
        create) name="$id"; a=(worktree create --name "$id" --no-parent)
                if type n1_config_val >/dev/null 2>&1 && [ "$(n1_config_val '.tracker.type' 2>/dev/null)" = jira ]; then a+=(--reference "$id"); fi
                a+=(--agent claude --prompt "$prompt") ;;
        launch) case "$path" in /*) ;; *) echo "handoff:failed (invalid path)"; return 0 ;; esac
                name="${path##*/}"; a=(agent launch --worktree "path:$path" --agent claude --prompt "$prompt") ;;
        *) echo "handoff:failed (invalid mode)"; return 0 ;;
    esac
    if ! out=$(N1_ORCA_TIMEOUT=120 n1_orca "${a[@]}"); then
        msg=$(jq -r '.error.message // empty' <<<"$out" 2>/dev/null | head -1 | tr -d '\r')
        echo "handoff:failed (${msg:-cli error})"; return 0
    fi
    handle=$(jq -r 'first(.. | objects | (.handle?, .agentTerminalHandle?) | strings) // empty' <<<"$out" 2>/dev/null)
    [ -n "$handle" ] || { echo "handoff:failed (no agent handle in result)"; return 0; }
    # Ticket rule: a prompt outcome other than journaled|handed-to-terminal means not delivered (absent = accepted until the live check pins the path).
    kind=$(jq -r '(.result.launch.outcome.kind? // .result.prompt.outcome.kind? // empty)' <<<"$out" 2>/dev/null)
    case "$kind" in ""|journaled|handed-to-terminal) ;; *) echo "handoff:failed (prompt $kind)"; return 0 ;; esac
    echo "handoff:ok $name $handle"
}
