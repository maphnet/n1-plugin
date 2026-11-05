#!/usr/bin/env bash
# Observe PR creation; a branch without a pre-push Codex receipt gets a step-not-run receipt (N1-405).
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
URLS=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // .error // empty' | grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//') || URLS=""
[ -n "$URLS" ] || exit 0
# N1-405: receipts are keyed on the branch of the checkout that ran gh pr create.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
BRANCH=$(git -C "${CWD:-.}" branch --show-current 2>/dev/null) || BRANCH=""
file=$(n1_review_receipt "$BRANCH") || exit 0
{ [ ! -f "$file" ] && [ -z "$(n1_review_outcome "$BRANCH")" ]; } || exit 0
n1_review_record "$BRANCH" skipped step-not-run false
jq -n --arg event "$EVENT" --arg urls "$URLS" --arg b "$BRANCH" '{hookSpecificOutput:{hookEventName:$event,additionalContext:("N1: the Codex review did not run before push on branch " + $b + " (PRs " + $urls + "). Read n1-pr step 3; it records the outcome and discloses the PR as not Codex-reviewed.")}}'
