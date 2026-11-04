#!/usr/bin/env bash
# N1-342: stuck detector for a repeated identical failing Bash call inside one session/agent.
#   PostToolUseFailure (Bash): records the streak; the 3rd identical failure gets one additionalContext nudge.
#   PreToolUse (Bash): once 5 identical failures are recorded, the same call is denied (exit 2, reason on stderr).
#   PostToolUse (Bash and edit tools): a success deletes the caller's state; an edit deletes every agent's state in the session.
# Identical = same tool_input without .description, and the same normalized error (first 3 lines, digit runs
# -> N, 300 bytes). State: $N1_HOME/scratch/stuck/<session_id>.<agent_id|main>, one line "H F count flag",
# hashes only. Telemetry: {"event":"stuck","kind":"nudge|stop"} in raw/steps when the session owns a run lock.
# Fail-open: any error exits 0 with no output; exit 2 is only the deliberate deny.
# ponytail: streak of 1 (last failure hash + count); keep a ring of hashes if A-B-A-B alternation matters.
set -u
export LC_ALL=C
INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUDGE_AT=3; DENY_AT=5
# Raw standalone polls exit non-zero while pending (gh pr checks: 8) with identical normalized errors; never a streak.
POLL_RE='^[[:space:]]*(n1_wait_|[^[:space:]]*lib/poll\.sh|gh[[:space:]]+(pr[[:space:]]+checks|run[[:space:]]+(list|view|watch)))'
ID_RE='^[A-Za-z0-9_-]+$'

IFS=$'\x1f' read -r ev tool sid aid cwd < <(jq -r '[.hook_event_name, .tool_name, .session_id,
    (.agent_id // "" | if . == "" then "main" else . end), .cwd] | map(. // "" | tostring) | join("\u001f")' \
    <<<"$INPUT" 2>/dev/null) || exit 0
[[ "$sid" =~ $ID_RE && "$aid" =~ $ID_RE ]] || exit 0
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
source "${SCRIPT_DIR}/../lib/host.sh" 2>/dev/null || exit 0
N1_HOME=$(n1_home 2>/dev/null)
[ -n "$N1_HOME" ] || exit 0
D="$N1_HOME/scratch/stuck"; S="$D/$sid.$aid"
[ ! -L "$N1_HOME/scratch" ] && [ ! -L "$D" ] && [ ! -L "$S" ] || exit 0

if [ "$ev" = PostToolUse ]; then
    case "$tool" in   # an edit anywhere in the session changes the world for every agent
        Edit|Write|MultiEdit|NotebookEdit) rm -f "$D/$sid".* 2>/dev/null ;;
        *) rm -f "$S" 2>/dev/null ;;
    esac
    exit 0
fi
[ "$tool" = Bash ] || exit 0
case "$ev" in PreToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac
if [ "$ev" = PreToolUse ] && [ ! -f "$S" ]; then exit 0; fi   # hot path: no streak, nothing to deny

source "${SCRIPT_DIR}/../lib/treestate.sh" 2>/dev/null || exit 0
H=$({ printf '%s\0' "$tool"; jq -S -c '.tool_input | if type == "object" then del(.description) else . end' <<<"$INPUT"; } | _n1_sha256)
[ -n "$H" ] || exit 0
sH=""; sF=""; cnt=0; flag=0
if [ -f "$S" ]; then
    read -r sH sF cnt flag < "$S" 2>/dev/null || true
    [[ "${cnt:-}" =~ ^[0-9]+$ && "${flag:-}" =~ ^[012]$ ]] || { sH=""; sF=""; cnt=0; flag=0; }
fi

save() { # <H> <F> <count> <flag>: atomic replace via mktemp in the same dir + mv
    local tmp
    mkdir -p "$D" 2>/dev/null && [ ! -L "$D" ] || return 1
    tmp=$(mktemp "$D/.tmp.XXXXXX" 2>/dev/null) || return 1
    if printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$tmp" && mv -f "$tmp" "$S" 2>/dev/null; then return 0; fi
    rm -f "$tmp"; return 1
}

telem() { # <kind> <count> <failure-hash>: no-op unless this session owns exactly one run lock
    ( source "${SCRIPT_DIR}/../lib/telemetry.sh" 2>/dev/null || exit 0
      export N1_SESSION_ID="$sid"
      n1_read_lock "$N1_HOME/memory" 2>/dev/null || exit 0
      out="$N1_LOCK_TELEM_DIR/raw/steps/$N1_LOCK_RUN_ID.jsonl"
      mkdir -p "${out%/*}" 2>/dev/null || exit 0
      jq -cn --arg k "$1" --argjson c "$2" --arg h "${3:0:12}" --arg r "$N1_LOCK_RUN_ID" --arg t "$N1_LOCK_TICKET_ID" \
          --arg s "$sid" --arg a "$aid" --arg tool "$tool" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{event:"stuck",kind:$k,run_id:$r,ticket_id:$t,session_id:$s,agent_id:$a,tool:$tool,count:$c,hash:$h,timestamp:$ts}' \
          >> "$out" 2>/dev/null
    ) || true
}

if [ "$ev" = PostToolUseFailure ]; then
    cmd=$(jq -r '.tool_input.command // "" | strings' <<<"$INPUT" 2>/dev/null)
    # Standalone polls only: a chained command (&& ; || |) falls through to normal failure tracking.
    [[ "$cmd" =~ $POLL_RE && ! "$cmd" =~ [\;\&\|] ]] && exit 0
    norm=$(jq -r '.error // "" | strings' <<<"$INPUT" 2>/dev/null | head -n 3 | sed -E 's/[0-9]+/N/g' | head -c 300)
    F=$({ printf '%s\0' "$H"; printf '%s' "$norm"; } | _n1_sha256)
    [ -n "$F" ] || exit 0
    if [ "$sF" = "$F" ]; then cnt=$((cnt + 1)); else cnt=1; flag=0; fi
    nudge=0
    if [ "$cnt" -ge "$NUDGE_AT" ] && [ "$flag" = 0 ]; then nudge=1; flag=1; fi
    save "$H" "$F" "$cnt" "$flag" || exit 0
    [ "$nudge" = 1 ] || exit 0
    telem nudge "$cnt" "$F"
    jq -nc --arg c "N1 stuck detector: this exact Bash call has failed $cnt times in a row with the same error. Do not retry it unchanged. Read the error, check your assumptions and change the approach: fix the cause, run a different command, or report the blocker. After $DENY_AT identical failures the same call is denied." \
        '{hookSpecificOutput:{hookEventName:"PostToolUseFailure",additionalContext:$c}}'
    exit 0
fi

# PreToolUse: deny the identical call once DENY_AT identical failures are recorded; telemetry stop once per streak.
[ "$sH" = "$H" ] && [ "$cnt" -ge "$DENY_AT" ] || exit 0
if [ "$flag" != 2 ]; then save "$sH" "$sF" "$cnt" 2 && telem stop "$cnt" "$sF"; fi
echo "N1 stuck detector: denied. This exact Bash call failed $cnt times in a row with the same error. Change the approach: fix the cause, run a different command, or report the blocker. Any successful command or file edit clears this block." >&2
exit 2
