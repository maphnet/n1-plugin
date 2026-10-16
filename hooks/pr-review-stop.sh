#!/usr/bin/env bash
# One continuation request per unprocessed PR; receipt remains on repeated Stop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/codex-review.sh"
INPUT=$(cat)
sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0
export N1_SESSION_ID="$sid"
N1_HOME=$(n1_home)
[ -n "$N1_HOME" ] || exit 0
urls=()
for file in "$N1_HOME/review-receipts/$sid/"*.json; do
    [ -f "$file" ] || continue
    jq -e '.processed == false and .reminded != true' "$file" >/dev/null || continue
    urls+=("$(jq -r .pr_url "$file")")
    tmp=$(mktemp "${file}.XXXXXX")
    jq '. + {reminded:true}' "$file" > "$tmp"
    mv "$tmp" "$file"
done
[ "${#urls[@]}" -gt 0 ] || exit 0
if printf '%s' "$INPUT" | jq -e '.stop_hook_active == true' >/dev/null; then exit 0; fi
jq -n --arg urls "${urls[*]}" '{decision:"block",reason:("N1: Codex review step was not run for " + $urls + ". Read n1-pr step 3 and execute scripts/codex-pr-review.sh for each PR before the final report. A skipped/step-not-run receipt has been saved.")}'
