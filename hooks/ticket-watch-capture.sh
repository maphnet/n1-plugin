#!/usr/bin/env bash
# PostToolUse hook (jcm_getIssue, jcm_getIssueChangelog, jcm_searchIssues): saves the raw response for a
# ticket that has an N1 memory dir into its ticket-watch file, so the orchestrator never re-types the
# payload (N1-314; skills/n1-start/procedures/ticket-watch.md). The payload is untrusted tracker text:
# written as a file only, never evaluated. Fail-open and silent: every path exits 0 with no stdout, so
# the tool result is never blocked or changed.
# ponytail: any call for a key with a memory dir is captured (subagents, an older ticket's dir); each
# procedure section removes its files before its own call, so a stray capture is never read.
set -u
export LC_ALL=C
INPUT=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/config.sh" 2>/dev/null || exit 0
tool=$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null) || exit 0
case "$tool" in
    mcp__*__jcm_getIssue) name=.tw-issue.json ;;
    mcp__*__jcm_getIssueChangelog) name=log ;;
    mcp__*__jcm_searchIssues) name=.tw-probe.json ;;
    *) exit 0 ;;
esac
if [ "$name" = .tw-probe.json ]; then
    # Only the watch probe's exact single-key JQL; any other search is not ours.
    key=$(jq -r '(.tool_input.jql // "") | capture("^key = (?<k>\\S+)$") | .k' <<<"$INPUT" 2>/dev/null)
else
    key=$(jq -r '.tool_input.issueKey // empty' <<<"$INPUT" 2>/dev/null)
fi
[[ "${key:-}" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || exit 0
cwd=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
home=$(n1_home 2>/dev/null)
[ -n "$home" ] || exit 0
M="$home/memory/$key"
[ -d "$M" ] || exit 0
if [ "$name" = log ]; then
    name=""
    for n in 1 2 3 4 5; do [ -e "$M/.tw-log-$n.json" ] || { name=".tw-log-$n.json"; break; }; done
    [ -n "$name" ] || exit 0
fi
tmp=$(mktemp "$M/$name.XXXXXX" 2>/dev/null) || exit 0
# Unwrap: content-block array, MCP result object {content:[text blocks]}, plain string, or the payload
# object itself. The real MCP tool_response shape is undocumented; verify it on a live call (post-merge).
if jq -j '.tool_response
    | if type == "string" then .
      elif type == "array" then [.[] | select(type == "object" and .type == "text") | .text] | join("")
      elif type == "object" and (.content | type) == "array" and (.content | length) > 0
           and all(.content[]; type == "object" and .type == "text") then [.content[].text] | join("")
      elif type == "object" then tojson
      else error("no payload") end' <<<"$INPUT" > "$tmp" 2>/dev/null \
   && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$M/$name" 2>/dev/null || rm -f "$tmp"
else
    rm -f "$tmp"
fi
exit 0
