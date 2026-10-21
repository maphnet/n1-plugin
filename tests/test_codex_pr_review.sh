#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export N1_HOME="$TMP/n1" N1_SESSION_ID=review-test
mkdir -p "$N1_HOME" "$TMP/bin"
printf '{}\n' > "$N1_HOME/config.json"
export PATH="$TMP/bin:$PATH" REVIEW_LOG="$TMP/log"
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
if [ "$1" = login ]; then
  case "${AUTH_MODE:-ok}" in hang) sleep 10;; fail) exit 1;; esac
  exit 0
fi
printf 'review\n' >> "$REVIEW_LOG"
[ "${REVIEW_MODE:-ok}" != hang ] || sleep 10
[ "${REVIEW_MODE:-ok}" != fail ] || exit 1
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'No findings.\n' > "$2"; break; fi
  shift
done
SH
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$2" = diff ]; then
  [ "${DIFF_MODE:-ok}" != fail ] || exit 1
  printf 'diff --git a/example.md b/example.md\n'
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf '%s\n' "$*" >> "${REVIEW_LOG}.list"
  [ "${LIST_MODE:-ok}" != fail ] || exit 1
  [ -z "${PR_LIST_URLS:-}" ] || printf '%s\n' "$PR_LIST_URLS"
  exit 0
fi
cat > "${REVIEW_LOG}.comment"
[ "${POST_MODE:-ok}" != fail ]
SH
chmod +x "$TMP/bin/"*
URL=https://github.com/example/repo/pull/42
payload=$(jq -nc --arg u "$URL" '{session_id:"review-test",tool_name:"Bash",tool_input:{command:"gh pr create --title test"},tool_response:{stdout:$u,exit_code:0}}')
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" > "$TMP/observe"
receipt="$N1_HOME/review-receipts/review-test/example_repo_42.json"
jq -e '.outcome == "skipped" and .reason == "step-not-run" and (.processed | not)' "$receipt" >/dev/null
printf '{"session_id":"review-test"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/stop"
jq -e '.decision == "block"' "$TMP/stop" >/dev/null
printf '{"session_id":"other"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/other"
[ ! -s "$TMP/other" ]
printf '{"session_id":"review-test","stop_hook_active":true}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/retry"
[ ! -s "$TMP/retry" ]
printf 'PASS: omitted step records skip and requests continuation once, isolated by session\n'
for scenario in disabled no-auth auth-timeout ran ran-optout failed timeout post-failed diff-unavailable; do
  unset AUTH_MODE REVIEW_MODE POST_MODE DIFF_MODE
  printf '{}\n' > "$N1_HOME/config.json"
  case "$scenario" in
    disabled) printf '{"crossHostReview":{"enabled":false}}\n' > "$N1_HOME/config.json";;
    ran-optout) printf '{"crossHostReview":{"autoTriage":false}}\n' > "$N1_HOME/config.json";;
    no-auth) export AUTH_MODE=fail;;
    auth-timeout) export AUTH_MODE=hang;;
    failed) export REVIEW_MODE=fail;;
    timeout) export REVIEW_MODE=hang;;
    post-failed) export POST_MODE=fail; rm -rf "$(dirname "$receipt")";;
    diff-unavailable) export DIFF_MODE=fail;;
  esac
  N1_CODEX_AUTH_TIMEOUT=0.1 N1_CROSS_HOST_REVIEW_TIMEOUT=0.1 bash "$ROOT/scripts/codex-pr-review.sh" "$URL" > "$TMP/out"
  expected=$scenario
  case "$scenario" in disabled|no-auth|auth-timeout) expected=skipped;; post-failed|ran-optout) expected=ran;; diff-unavailable) expected=failed;; esac
  jq -e --arg expected "$expected" '.outcome == $expected and .processed' "$receipt" >/dev/null
  if [ "$expected" = skipped ]; then jq -e --arg reason "$scenario" '.reason == $reason' "$receipt" >/dev/null; fi
  if [ "$scenario" = ran ]; then grep -Eq '^## Codex Review' "${REVIEW_LOG}.comment"; fi
  if [ "$scenario" = ran ]; then
    grep -qx -- '--- codex output ---' "$TMP/out"
    grep -qx 'crossHostReview_autoTriage=true' "$TMP/out"
  fi
  if [ "$scenario" = ran-optout ]; then
    # `! grep` does not trip set -e, so fail explicitly.
    if grep -qx -- '--- codex output ---' "$TMP/out"; then echo 'FAIL: autoTriage=false still prints findings'; exit 1; fi
    grep -qx 'crossHostReview_autoTriage=false' "$TMP/out"
  fi
  if [ "$scenario" = post-failed ]; then
    jq -e '.comment == "saved"' "$receipt" >/dev/null
    grep -Eq '^## Codex Review' "${receipt%.json}.md"
  fi
  if [ "$scenario" = diff-unavailable ]; then jq -e '.reason == "diff-unavailable"' "$receipt" >/dev/null; fi
  if [ "$scenario" = failed ] || [ "$scenario" = timeout ]; then [ -f "${receipt%.json}.stderr.log" ]; fi
  printf 'PASS: %s produces a terminal receipt\n' "$scenario"
done
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" >/dev/null
jq -e '.processed' "$receipt" >/dev/null
printf 'PASS: observing the same PR preserves its completed receipt\n'
payload=$(jq -nc '{session_id:"multi-pr",tool_name:"Bash",tool_input:{command:"gh pr create; gh pr create"},tool_response:{stdout:"https://github.com/example/repo/pull/1\nhttps://github.com/example/repo/pull/2",exit_code:0}}')
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" > "$TMP/multi"
jq -se 'length == 1 and (.[0].hookSpecificOutput.additionalContext | contains("pull/1") and contains("pull/2"))' "$TMP/multi" >/dev/null
printf 'PASS: multiple PRs produce one structured hook response\n'
payload=$(jq -nc '{session_id:"active-stop",tool_input:{command:"gh pr create"},tool_response:{stdout:"https://github.com/example/repo/pull/43"}}')
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" >/dev/null
printf '{"session_id":"active-stop","stop_hook_active":true}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/active-stop"
[ ! -s "$TMP/active-stop" ]
jq -e '.reminded != true' "$N1_HOME/review-receipts/active-stop/example_repo_43.json" >/dev/null
printf '{"session_id":"active-stop"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/next-stop"
jq -e '.decision == "block"' "$TMP/next-stop" >/dev/null
printf 'PASS: another Stop continuation does not consume an unsent reminder\n'
payload=$(jq -nc '{session_id:"failed-tail",hook_event_name:"PostToolUseFailure",tool_input:{command:"gh pr create && false"},error:"Exit code 1\nhttps://github.com/example/repo/pull/44"}')
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" > "$TMP/failed-tail"
jq -e '.outcome == "skipped" and .reason == "step-not-run"' "$N1_HOME/review-receipts/failed-tail/example_repo_44.json" >/dev/null
jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"' "$TMP/failed-tail" >/dev/null
jq -e '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("pr-review-observe.sh"))' "$ROOT/hooks/hooks.json" >/dev/null
printf 'PASS: failed command tail still observes its created PR\n'
# PR on the active run's branch with no receipt (PostToolUse missed it) is caught at Stop.
unset AUTH_MODE REVIEW_MODE POST_MODE DIFF_MODE
printf '{}\n' > "$N1_HOME/config.json"
WT="$TMP/wt"
git init -q "$WT"
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WT" update-ref refs/remotes/origin/feature/T-1 HEAD
printf '{"ticketId":"T-1","runId":"r","worktreePath":"%s","branch":"feature/T-1"}\n' "$WT" > "$N1_HOME/active-run.run-stop.json"
export PR_LIST_URLS=https://github.com/example/repo/pull/50
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"run-stop"}' > "$TMP/run-stop"
jq -e '.decision == "block" and (.reason | contains("pull/50"))' "$TMP/run-stop" >/dev/null
jq -e '.outcome == "skipped" and .reason == "step-not-run" and (.processed | not)' "$N1_HOME/review-receipts/run-stop/example_repo_50.json" >/dev/null
grep -q -- '--head feature/T-1' "${REVIEW_LOG}.list"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"run-stop"}' > "$TMP/run-stop-2"
[ ! -s "$TMP/run-stop-2" ]
printf 'PASS: Stop records and blocks once for an unreceipted PR on the run branch\n'
check_run() { N1_SESSION_ID="$1" bash -c 'source "$1/lib/codex-review.sh"; n1_review_check_run' _ "$ROOT"; }
[ "$(check_run run-stop)" = "$PR_LIST_URLS" ]
N1_SESSION_ID=run-stop bash -c 'source "$1/lib/codex-review.sh"; n1_review_record "$2" ran "" true' _ "$ROOT" "$PR_LIST_URLS"
[ -z "$(check_run run-stop)" ]
printf 'PASS: run check lists the PR until a processed receipt exists\n'
printf '{"ticketId":"T-1","runId":"r","worktreePath":"%s","branch":"feature/T-1"}\n' "$WT" > "$N1_HOME/active-run.resumed.json"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"resumed"}' > "$TMP/resumed"
[ ! -s "$TMP/resumed" ]
[ ! -e "$N1_HOME/review-receipts/resumed" ]
printf 'PASS: a processed receipt from another session satisfies the run check\n'
printf '{"ticketId":"T-1","runId":"r","worktreePath":"%s","branch":"feature/T-1"}\n' "$WT" > "$N1_HOME/active-run.mixed.json"
rm -rf "$N1_HOME/review-receipts/run-stop"
mkdir -p "$N1_HOME/review-receipts/other-a" "$N1_HOME/review-receipts/other-b"
rcpt=$(N1_SESSION_ID=x bash -c 'source "$1/lib/codex-review.sh"; n1_review_receipt "$2"' _ "$ROOT" "$PR_LIST_URLS")
printf '{"pr_url":"%s","processed":false}\n' "$PR_LIST_URLS" > "$N1_HOME/review-receipts/other-a/${rcpt##*/}"
printf '{"pr_url":"%s","processed":true}\n' "$PR_LIST_URLS" > "$N1_HOME/review-receipts/other-b/${rcpt##*/}"
[ -z "$(check_run mixed)" ]
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"mixed"}' > "$TMP/mixed"
[ ! -s "$TMP/mixed" ]
printf 'PASS: any processed receipt wins over an unprocessed one from another session\n'
: > "${REVIEW_LOG}.list"
N1_SESSION_ID=mixed bash -c 'command() { [ "${2:-}" = timeout ] && return 1; builtin command "$@"; }; source "$1/lib/codex-review.sh"; n1_review_check_run' _ "$ROOT" >/dev/null
[ ! -s "${REVIEW_LOG}.list" ]
printf 'PASS: no timeout binary skips the PR lookup instead of running gh unbounded\n'
git -C "$WT" update-ref -d refs/remotes/origin/feature/T-1
printf '{"ticketId":"T-1","runId":"r","worktreePath":"%s","branch":"feature/T-1"}\n' "$WT" > "$N1_HOME/active-run.unpushed.json"
: > "${REVIEW_LOG}.list"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"unpushed"}' > "$TMP/unpushed"
[ ! -s "$TMP/unpushed" ] && [ ! -s "${REVIEW_LOG}.list" ]
printf 'PASS: an unpushed run branch skips the PR lookup\n'
printf '{"ticketId":"T-2","runId":"r","worktreePath":null,"branch":"feature/T-2"}\n' > "$N1_HOME/active-run.offline.json"
LIST_MODE=fail bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"offline"}' > "$TMP/offline"
[ ! -s "$TMP/offline" ]
[ ! -e "$N1_HOME/review-receipts/offline" ]
printf '{"ticketId":"T-3","runId":"r","worktreePath":null,"branch":"main"}\n' > "$N1_HOME/active-run.default.json"
: > "${REVIEW_LOG}.list"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"default"}' > "$TMP/default"
[ ! -s "$TMP/default" ]
[ ! -s "${REVIEW_LOG}.list" ]
printf '{"ticketId":"T-4","runId":"r","worktreePath":null,"branch":"feature/T-4"}\n' > "$N1_HOME/active-run.json"
: > "${REVIEW_LOG}.list"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"unkeyed"}' > "$TMP/unkeyed"
[ ! -s "$TMP/unkeyed" ] && [ ! -s "${REVIEW_LOG}.list" ]
bash "$ROOT/hooks/session-stop.sh" <<<'{"session_id":"offline"}' >/dev/null
printf 'PASS: gh failure, default-branch and unkeyed-pointer runs fail open with no block and no gh call\n'
