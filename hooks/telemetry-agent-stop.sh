#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/telemetry.sh"

N1_HOME=$(n1_home)
INPUT=$(cat)
# N1-315: an Orca queue child beacons its phase to the coordinator. Runs before the no-lock exit below.
if source "${SCRIPT_DIR}/../lib/orca-queue.sh" 2>/dev/null && n1_orca_child_env "${CLAUDE_PROJECT_DIR:-$PWD}" "$(printf '%s' "$INPUT" | n1_hook_field session_id)"; then
    source "${SCRIPT_DIR}/../lib/frontmatter.sh"
    n1_orca_beacon stop "$(printf '%s' "$INPUT" | n1_hook_field agent_type)" || true
fi
N1_SESSION_ID=$(printf '%s' "$INPUT" | n1_hook_field session_id)
export N1_SESSION_ID="${N1_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
n1_read_lock "$N1_HOME/memory" || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | n1_hook_field agent_id)
AGENT_TYPE=$(printf '%s' "$INPUT" | n1_hook_field agent_type)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | n1_hook_field transcript_path)

SESSION_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"

[ -n "$(n1_persona_name "$AGENT_TYPE")" ] || exit 0
[ -n "$AGENT_ID" ] || exit 0

# The payload's transcript_path is the PARENT session transcript; the subagent's own
# transcript lives at <parent-minus-.jsonl>/subagents/agent-<agent_id>.jsonl. Prefer it —
# otherwise every agent gets attributed the whole session's token totals.
if [ -n "$TRANSCRIPT_PATH" ]; then
    AGENT_TRANSCRIPT="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
    [ -f "$AGENT_TRANSCRIPT" ] && TRANSCRIPT_PATH="$AGENT_TRANSCRIPT"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTFILE="${N1_LOCK_TELEM_DIR}/raw/agents/${N1_LOCK_RUN_ID}.jsonl"
mkdir -p "$(dirname "$OUTFILE")"

# N1-317: report (never kill) `bash -c` / `sh -c` shells still running in the run's worktree when a persona stops.
# Linux /proc only; any missing piece (no /proc, jq, ps etimes, worktree) yields nothing. Prints "<pid> <age_s>" per
# shell not reported before (marker $N1_HOME/.stop-leftovers-<run>, keyed pid:starttime). Shells that started before
# this agent's start event are skipped; later ones from a parallel persona or the orchestrator cannot be told apart.
n1_stop_leftovers() {
    [ -r /proc/self/cwd ] || return 0
    local root="" af cwd started="" since="" now anc=" " pid d argv0 argv1 dir et stat st marker
    local -a f
    af=$(n1_active_run_file 2>/dev/null) || af=""
    [ -n "$af" ] && [ -f "$af" ] && root=$(jq -r '.worktreePath // empty' "$af" 2>/dev/null) || true
    if [ -z "$root" ]; then
        cwd=$(printf '%s' "$INPUT" | n1_hook_field cwd)
        [ -n "$cwd" ] && root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || true
    fi
    [ -n "$root" ] && [ -d "$root" ] || return 0
    root=$(cd "$root" && pwd -P) || return 0
    started=$(jq -r --arg a "$AGENT_ID" 'select(.event == "start" and .agent_id == $a) | .started_at' "$OUTFILE" 2>/dev/null | tail -n 1) || started=""
    [ -z "$started" ] || since=$(date -u -d "$started" +%s 2>/dev/null) || since=""
    now=$(date +%s)
    pid=$$  # this hook and its ancestors (the harness `sh -c` wrapper) are never leftovers
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        anc="$anc$pid "
        pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null) || pid=""
    done
    marker="$N1_HOME/.stop-leftovers-$N1_LOCK_RUN_ID"
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$anc" in *" $pid "*) continue ;; esac
        { IFS= read -r -d '' argv0 && IFS= read -r -d '' argv1; } 2>/dev/null < "$d/cmdline" || continue
        case "${argv0##*/}" in bash|sh) ;; *) continue ;; esac
        [ "$argv1" = "-c" ] || continue
        dir=$(readlink "$d/cwd" 2>/dev/null) || continue
        case "$dir/" in "$root"/*) ;; *) continue ;; esac
        et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ') || continue
        case "$et" in ''|*[!0-9]*) continue ;; esac
        [ -z "$since" ] || [ $((now - et)) -ge "$since" ] || continue
        read -r stat 2>/dev/null < "$d/stat" || continue
        read -r -a f <<< "${stat##*) }"
        st=${f[19]:-}   # field 22 (starttime, clock ticks since boot): a stable dedupe key, unlike now-etimes
        grep -qxF "$pid:$st" "$marker" 2>/dev/null && continue
        printf '%s\n' "$pid:$st" >> "$marker" 2>/dev/null || true
        printf '%s %s\n' "$pid" "$et"
    done
}

LEFT=$(n1_stop_leftovers || true)
LEFTOVER_JSON=""
if [ -n "$LEFT" ]; then
    items="" text=""
    while read -r p a; do
        items="${items:+$items,}{\"pid\":$p,\"age_s\":$a}"
        text="${text:+$text, }pid $p age ${a}s"
    done <<< "$LEFT"
    # systemMessage on stdout: the harness shows it for a synchronous hook (exit-0 stderr is not surfaced)
    msg=$(printf 'N1: warning -- %s stopped with shell(s) still running in the worktree (possibly from a parallel persona): %s (reported, not killed)' \
        "$(n1_persona_name "$AGENT_TYPE")" "$text")
    printf '{"systemMessage":"%s"}\n' "$(escape_json_val "$msg")"
    LEFTOVER_JSON=",\"leftover_shells\":[$items]"
fi

echo "{\"run_id\":\"$(escape_json_val "$N1_LOCK_RUN_ID")\",\"n1_version\":\"$(escape_json_val "$N1_LOCK_VERSION")\",\"ticket_id\":\"$(escape_json_val "$N1_LOCK_TICKET_ID")\",\"layer\":\"agent\",\"event\":\"stop\",\"agent_id\":\"$(escape_json_val "$AGENT_ID")\",\"agent_type\":\"$(escape_json_val "$AGENT_TYPE")\",\"completed_at\":\"${TIMESTAMP}\",\"transcript_path\":\"$(escape_json_val "$TRANSCRIPT_PATH")\",\"session_transcript_path\":\"$(escape_json_val "$SESSION_TRANSCRIPT_PATH")\"${LEFTOVER_JSON}}" >> "$OUTFILE"
