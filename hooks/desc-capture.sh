#!/usr/bin/env bash
# PostToolUse hook (jcm_getIssue, N1-326): writes a fetched ticket's title and description into the files that
# references/desc-hash-chain.md, the headless Content check and n1-queue hash with n1_queue_content_hash, so the
# model never relays tracker text into a file. It acts only on the one-shot marker the calling session's skill
# wrote with n1_desc_mark (lib/queue.sh): $N1_HOME/.desc-marker/<session_id>/<KEY>, holding "pre", "post",
# "guard" or "queue <queue-id>". The marker is claimed (moved) before anything else, so a later getIssue on the
# same key writes nothing. Subagent calls capture too: product-analyst fetches in a subagent that shares the
# session_id, and the marker written by the session's own bash is the trust anchor (no agent_id/owner gate).
# The payload is untrusted tracker text: parsed by jq into files only, never evaluated or echoed; no stdout.
# Fail-open: any miss exits 0 and writes nothing; the readers then fail closed on the missing file.
set -u
export LC_ALL=C
INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
KEY_RE='^[A-Z][A-Z0-9_]*-[0-9]+$'        # SEC-L4, same as n1-queue intake
QID_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'    # same as the n1-queue SKILL.md queue id

tool=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || exit 0
case "$tool" in mcp__*__jcm_getIssue) ;; *) exit 0 ;; esac
sid=$(jq -r '.session_id // empty | strings' <<<"$INPUT" 2>/dev/null)
key=$(jq -r '.tool_input.issueKey // empty | strings' <<<"$INPUT" 2>/dev/null)
[[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ "$key" =~ $KEY_RE ]] || exit 0
cwd=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
N1_HOME=$(n1_home 2>/dev/null)
[ -n "$N1_HOME" ] || exit 0

# Claim the marker: only the hook that wins the move proceeds, and the marker is gone whatever happens next.
MD="$N1_HOME/.desc-marker"; MK="$MD/$sid/$key"
[ ! -L "$MD" ] && [ ! -L "$MD/$sid" ] && [ -f "$MK" ] && [ ! -L "$MK" ] || exit 0
CL="$MK.claim.$$"
mv -f "$MK" "$CL" 2>/dev/null || exit 0
mark=$(head -c 256 "$CL" 2>/dev/null); rm -f "$CL"

case "$mark" in
    pre)   D="$N1_HOME/memory/$key"; F="$D/.desc-pre" ;;
    post)  D="$N1_HOME/memory/$key"; F="$D/.desc-post" ;;
    guard) D="$N1_HOME/memory/$key"; F="$D/.guard-live" ;;
    "queue "*)
        qid=${mark#queue }
        [[ "$qid" =~ $QID_RE ]] || exit 0
        Q="$N1_HOME/queue/$qid"
        [ -d "$Q" ] && [ ! -L "$Q" ] || exit 0
        D="$Q/desc"
        [ -L "$D" ] && exit 0
        mkdir -p "$D" 2>/dev/null || exit 0
        F="$D/$key" ;;
    *) exit 0 ;;
esac
[ -d "$D" ] && [ ! -L "$D" ] || exit 0   # a committed in-repo .n1 could plant a symlink here

# Join the response's text blocks exactly as ticket-watch-capture.sh save() does.
JOIN='.tool_response
    | if type == "string" then .
      elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text] | join("")
      elif type == "object" and (.content | type) == "array" and (.content | length) > 0
           and all(.content[]; type == "object" and .type == "text") then [.content[].text] | join("")
      else error("no payload") end'
raw=$(mktemp "$F.XXXXXX" 2>/dev/null) || exit 0
tt=$(mktemp "$F.XXXXXX" 2>/dev/null) || { rm -f "$raw"; exit 0; }
td=$(mktemp "$F.XXXXXX" 2>/dev/null) || { rm -f "$raw" "$tt"; exit 0; }
trap 'rm -f "$raw" "$tt" "$td"' EXIT
jq -j "$JOIN" <<<"$INPUT" > "$raw" 2>/dev/null || exit 0
# Exactly one JSON object for this key with a string summary and a string or null description.
jq -se --arg k "$key" 'length == 1 and (.[0] | type == "object" and (.summary | type) == "string"
    and ((.description | type) == "string" or .description == null)
    and ((.key // $k) == $k))' "$raw" >/dev/null 2>&1 || exit 0
jq -j '.summary' "$raw" > "$tt" 2>/dev/null && jq -j '.description // ""' "$raw" > "$td" 2>/dev/null || exit 0
# Temp files, not $(...), so trailing newlines survive (byte parity with n1_queue_content_hash); title last.
mv -f "$td" "$F.txt" 2>/dev/null && mv -f "$tt" "$F.title" 2>/dev/null
exit 0
