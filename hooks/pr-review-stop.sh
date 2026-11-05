#!/usr/bin/env bash
# One continuation request per unprocessed branch receipt; receipt remains on repeated Stop.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../lib/codex-review.sh"
INPUT=$(cat)
if printf '%s' "$INPUT" | jq -e '.stop_hook_active == true' >/dev/null; then exit 0; fi
sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0
export N1_SESSION_ID="$sid"
N1_HOME=$(n1_home)
[ -n "$N1_HOME" ] || exit 0
# A PR created outside n1-pr has no PostToolUse receipt; find it via the run branch.
n1_review_check_run >/dev/null || true
branches=()
for file in "$(n1_review_root)/$sid/"*.json; do
    [ -f "$file" ] || continue
    jq -e '.processed == false and .reminded != true' "$file" >/dev/null || continue
    branches+=("$(jq -r '.branch // .pr_url // "unknown"' "$file")")
    tmp=$(mktemp "${file}.XXXXXX")
    jq '. + {reminded:true}' "$file" > "$tmp"
    mv "$tmp" "$file"
done
[ "${#branches[@]}" -gt 0 ] || exit 0
jq -n --arg b "${branches[*]}" '{decision:"block",reason:("N1: the Codex review did not run before push for branch " + $b + ". Read n1-pr step 3 and run it before the final report: it records the outcome and discloses the PR as not Codex-reviewed. Do not run Codex after the PR exists. A skipped/step-not-run receipt has been saved.")}'
