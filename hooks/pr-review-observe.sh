#!/usr/bin/env bash
# Observe successful PR creation even when the model never reads review step 3.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/codex-review.sh"
INPUT=$(cat)
export N1_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
N1_HOME=$(n1_home)
[ -n "$N1_HOME" ] || exit 0
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[[ "$COMMAND" =~ gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]] || exit 0
printf '%s' "$INPUT" | jq -e '(.tool_response.exit_code // 0) == 0' >/dev/null || exit 0
urls=()
while IFS= read -r url; do
    file=$(n1_review_receipt "$url") || continue
    [ ! -f "$file" ] || continue
    n1_review_record "$url" skipped step-not-run false
    urls+=("$url")
done < <(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // empty' | rg -o 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u)
[ "${#urls[@]}" -gt 0 ] || exit 0
jq -n --arg urls "${urls[*]}" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:("N1: PRs " + $urls + " need Codex review. Read n1-pr step 3 and run the review runner before reporting completion.")}}'
