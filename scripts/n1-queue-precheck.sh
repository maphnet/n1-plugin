#!/usr/bin/env bash
# scripts/n1-queue-precheck.sh — N1-226: Orca automation precheck for a scheduled n1-queue run. Orca runs it
# before every trigger: exit 0 starts the agent, any other exit records a skipped run and starts nothing.
# Self-contained on purpose: n1_queue_schedule copies it to <n1-home>/bin (the plugin root is a versioned cache
# path) and Orca's precheck cwd/env are undocumented, so it sources no n1 lib and needs only PATH and HOME.
# Usage: n1-queue-precheck.sh <n1-home> <tag> <tracker-mcp|none> <project-key> <todo-status>
# Skip (exit 1): a trigger claimed this queue under 15 minutes ago; any queue of the project is `step: run` with a
# live runner; Jira says zero tagged TODO tickets. Local checks fail closed. The tracker check fails open: only a
# definitive zero skips, because the agent's own MCP intake is authoritative and a wrong start costs one empty intake.
set -u
home="${1:?n1-home}" tag="${2:?tag}" mcp="${3:-none}" key="${4:-}" todo="${5:-}"
say() { echo "n1-queue precheck: $*" >&2; }

if [ -n "$(find "$home/queue/$tag/.unattended-claim" -maxdepth 0 -mmin -15 2>/dev/null)" ]; then
    say "claimed by another trigger less than 15 minutes ago; skip"; exit 1
fi

fm() {   # <file> <key> — minimal copy of n1_read_frontmatter (lib/frontmatter.sh)
    awk -v k="$2" 'NR==1 && /^---\r?$/ {f=1; next} f && /^---\r?$/ {exit}
        f && $0 ~ "^" k ":" {sub("^" k ":[[:space:]]*", ""); gsub(/\r/, ""); print; exit}' "$1" 2>/dev/null
}
alive() {   # <pid> <queue.md> — minimal copy of n1_queue_runner_alive (lib/queue.sh); tests assert both agree
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 0
    local arg hit=""
    while IFS= read -r -d '' arg; do
        if [ -n "$hit" ]; then [ "$arg" = "$2" ]; return; fi
        case "$arg" in */scripts/n1-queue-run.sh|scripts/n1-queue-run.sh) hit=1 ;; esac
    done < "/proc/$1/cmdline" 2>/dev/null
    return 1
}
for q in "$home"/queue/*/queue.md; do
    [ -f "$q" ] && [ "$(fm "$q" step)" = run ] || continue
    pid=$(fm "$q" pid)
    if alive "$pid" "$q"; then say "queue run live ($q, pid $pid); skip"; exit 1; fi
done

[ "$mcp" != none ] || { say "no REST tracker check for this tracker; start"; exit 0; }
env_file="${HOME:-}/.config/mcp/secrets/$mcp.env"
if [ ! -r "$env_file" ] || ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    say "tracker check unavailable (credentials file, curl or jq missing); start"; exit 0
fi
out=$(
    set -a; . "$env_file" >/dev/null 2>&1; set +a
    [ -n "${ATLASSIAN_URL:-}" ] && [ -n "${ATLASSIAN_EMAIL:-}" ] && [ -n "${ATLASSIAN_TOKEN:-}" ] || exit 2
    # Basic auth goes in through curl's stdin config, never argv (argv is readable by other processes).
    printf 'header = "Authorization: Basic %s"\n' "$(printf '%s:%s' "$ATLASSIAN_EMAIL" "$ATLASSIAN_TOKEN" | base64 | tr -d '\n')" \
    | curl -sSf --max-time 10 -K - -G "${ATLASSIAN_URL%/}/rest/api/3/search/jql" \
        --data-urlencode "jql=project = \"$key\" AND labels = \"$tag\" AND status = \"$todo\"" \
        --data-urlencode maxResults=1 --data-urlencode fields=key 2>/dev/null
) || { say "tracker check failed; start"; exit 0; }
n=$(jq -r 'if (.issues | type) == "array" then (.issues | length) else empty end' <<<"$out" 2>/dev/null)
case "$n" in
    0) say "no '$tag' tickets in '$todo'; skip"; exit 1 ;;
    ''|*[!0-9]*) say "unreadable tracker response; start"; exit 0 ;;
esac
exit 0
