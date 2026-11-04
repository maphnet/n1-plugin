#!/usr/bin/env bash
# Observe successful PR creation even when the model never reads review step 3.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/codex-review.sh"
INPUT=$(cat)
export N1_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
# N1-315: lib/step.sh writes step changes from Bash, so this hook sees them. Non-Orca sessions stop at the env test.
# ponytail: identity load per Bash call in an Orca child, cache per session if profiling shows cost.
if [ -n "${ORCA_CLI_COMMAND:-}" ] && source "$SCRIPT_DIR/../lib/orca-queue.sh" 2>/dev/null \
    && n1_orca_child_env "${CLAUDE_PROJECT_DIR:-$PWD}" "$N1_SESSION_ID"; then
    source "$SCRIPT_DIR/../lib/frontmatter.sh"
    n1_orca_beacon tick || true
fi
N1_HOME=$(n1_home)
[ -n "$N1_HOME" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]] || exit 0
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "PostToolUse"')
case "$EVENT" in PostToolUse|PostToolUseFailure) :;; *) exit 0;; esac
urls=()
while IFS= read -r url; do
    file=$(n1_review_receipt "$url") || continue
    [ ! -f "$file" ] || continue
    n1_review_record "$url" skipped step-not-run false
    urls+=("$url")
done < <(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // .error // empty' | grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u)
[ "${#urls[@]}" -gt 0 ] || exit 0
jq -n --arg event "$EVENT" --arg urls "${urls[*]}" '{hookSpecificOutput:{hookEventName:$event,additionalContext:("N1: PRs " + $urls + " need Codex review. Read n1-pr step 3 and run the review runner before reporting completion.")}}'
