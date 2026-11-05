#!/usr/bin/env bash
# N1-405: pre-push Codex runner (local branch diff), branch-keyed receipts, observe/Stop detection of a skipped step.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export N1_HOME="$TMP/n1" N1_STATE_DIR="$TMP/n1" N1_SESSION_ID=review-test
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
  if [ "$1" = -o ]; then printf '%s\n' "${CODEX_OUT:-No findings.}" > "$2"; break; fi
  shift
done
SH
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = pr ] && [ "$2" = list ]; then
  printf '%s\n' "$*" >> "${REVIEW_LOG}.list"
  [ "${LIST_MODE:-ok}" != fail ] || exit 1
  [ -z "${PR_LIST_URLS:-}" ] || printf '%s\n' "$PR_LIST_URLS"
  exit 0
fi
printf '%s\n' "$*" >> "${REVIEW_LOG}.gh"
SH
chmod +x "$TMP/bin/"*
gc() { git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q "${@:2}"; }
mkrepo() { # <dir> <branch>: a repo on <branch> one commit past its branch point; prints the branch point SHA
  git init -q -b "$2" "$1"; gc "$1" --allow-empty -m base; git -C "$1" rev-parse HEAD
  echo x > "$1/example.md"; git -C "$1" add example.md; gc "$1" -m change
}
observe() { # <session> <cwd> <stdout>: PostToolUse payload for gh pr create
  jq -nc --arg s "$1" --arg c "$2" --arg o "$3" \
    '{session_id:$s,cwd:$c,hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"gh pr create --title t"},tool_response:{stdout:$o,exit_code:0}}' \
    | bash "$ROOT/hooks/pr-review-observe.sh"
}

# AC5: a PR created on a branch whose pre-push Codex step never ran is caught at PostToolUse and at Stop.
SKIP="$TMP/skip"; mkrepo "$SKIP" feature/skip >/dev/null
observe review-test "$SKIP" https://github.com/example/repo/pull/42 > "$TMP/observe"
receipt="$N1_HOME/review-receipts/review-test/feature_skip.json"
jq -e '.branch == "feature/skip" and .outcome == "skipped" and .reason == "step-not-run" and (.processed | not)' "$receipt" >/dev/null
jq -e '.hookSpecificOutput.additionalContext | contains("did not run before push") and contains("pull/42")' "$TMP/observe" >/dev/null
printf '{"session_id":"review-test"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/stop"
jq -e '.decision == "block" and (.reason | contains("feature/skip"))' "$TMP/stop" >/dev/null
if grep -q 'codex-pr-review.sh' "$TMP/stop"; then echo 'FAIL: Stop still asks for a post-PR Codex run'; exit 1; fi
printf '{"session_id":"other"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/other"
[ ! -s "$TMP/other" ]
printf '{"session_id":"review-test","stop_hook_active":true}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/retry"
[ ! -s "$TMP/retry" ]
printf '{"session_id":"review-test"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/stop-2"
[ ! -s "$TMP/stop-2" ]
printf 'PASS: skipped pre-push step records step-not-run and requests continuation once, isolated by session\n'
observe review-test "$TMP" https://github.com/example/repo/pull/45 > "$TMP/no-branch"
[ ! -s "$TMP/no-branch" ]
printf 'PASS: gh pr create outside a branch checkout fails open\n'

# Runner: every scenario leaves a processed branch receipt; the runner never calls gh (AC6).
WT="$TMP/wt"; BASE=$(mkrepo "$WT" feature/T-1)
receipt="$N1_HOME/review-receipts/review-test/feature_T-1.json"
# A processed receipt from an earlier run on the same branch (another session) is cleared by the next runner run.
mkdir -p "$N1_HOME/review-receipts/old-sess"
printf '{"branch":"feature/T-1","outcome":"ran","processed":true}\n' > "$N1_HOME/review-receipts/old-sess/feature_T-1.json"
for scenario in disabled no-auth auth-timeout ran ran-optout ran-findings ran-noissues ran-fence-fail failed timeout memory-unavailable diff-unavailable; do
  unset AUTH_MODE REVIEW_MODE CODEX_OUT
  rm -rf "$N1_HOME/scratch" "$N1_HOME/memory" "$N1_HOME/x" "${REVIEW_LOG}.gh"
  printf '{}\n' > "$N1_HOME/config.json"
  B=$BASE; TID=T-1
  case "$scenario" in
    disabled) printf '{"crossHostReview":{"enabled":false}}\n' > "$N1_HOME/config.json";;
    ran-optout) printf '{"crossHostReview":{"autoTriage":false}}\n' > "$N1_HOME/config.json";;
    ran-findings) export CODEX_OUT=$'**High** - x\n[P2] y\nLow-level note';;
    ran-noissues) export CODEX_OUT='No issues found.';;
    ran-fence-fail) export CODEX_OUT=$'**High** - x\n[P2] y\nLow-level note'; : > "$N1_HOME/scratch";;
    no-auth) export AUTH_MODE=fail;;
    auth-timeout) export AUTH_MODE=hang;;
    failed) export REVIEW_MODE=fail;;
    timeout) export REVIEW_MODE=hang;;
    memory-unavailable) TID='../x'; rm -rf "$(dirname "$receipt")";;
    diff-unavailable) B=deadbeef;;
  esac
  (cd "$WT" && N1_CODEX_AUTH_TIMEOUT=0.1 N1_CROSS_HOST_REVIEW_TIMEOUT=0.1 bash "$ROOT/scripts/codex-pr-review.sh" "$B" "$TID") > "$TMP/out"
  if [ -e "$N1_HOME/review-receipts/old-sess/feature_T-1.json" ]; then echo "FAIL: $scenario: a stale receipt from an earlier run survived"; exit 1; fi
  expected=$scenario
  case "$scenario" in disabled|no-auth|auth-timeout) expected=skipped;; memory-unavailable|ran-optout|ran-findings|ran-noissues|ran-fence-fail) expected=ran;; diff-unavailable) expected=failed;; esac
  jq -e --arg expected "$expected" '.branch == "feature/T-1" and .outcome == $expected and .processed' "$receipt" >/dev/null
  if [ "$expected" = skipped ]; then jq -e --arg reason "$scenario" '.reason == $reason' "$receipt" >/dev/null; fi
  if [ -s "${REVIEW_LOG}.gh" ]; then echo "FAIL: $scenario: the runner called gh: $(cat "${REVIEW_LOG}.gh")"; exit 1; fi
  if [ "$scenario" = ran ]; then
    grep -qx 'No findings.' "$N1_HOME/memory/T-1/codex-review.md"
    jq -e '.comment == "saved"' "$receipt" >/dev/null
  fi
  if [ "$scenario" = ran ] || [ "$scenario" = ran-noissues ]; then
    grep -qx 'findings:none' "$TMP/out"
    grep -qx 'crossHostReview_autoTriage=true' "$TMP/out"
  fi
  if [ "$scenario" = ran-optout ]; then
    if grep -q '^findings:' "$TMP/out"; then echo 'FAIL: autoTriage=false still prints a findings line'; exit 1; fi
    grep -qx 'crossHostReview_autoTriage=false' "$TMP/out"
  fi
  if [ "$scenario" = ran-findings ] || [ "$scenario" = ran-fence-fail ]; then
    for m in '**High** - x' '[P2] y' 'Low-level note'; do
      if grep -qF -- "$m" "$TMP/out"; then echo "FAIL: $scenario prints raw Codex text on stdout: $m"; exit 1; fi
    done
  fi
  if [ "$scenario" = ran-findings ]; then
    fenced=$(sed -n 's/^findings:file=//p' "$TMP/out")
    [[ "$fenced" =~ ^"$N1_HOME"/scratch/codex-findings-feature_T-1\.[A-Za-z0-9]{6}\.md\.fenced$ ]]
    [ "$(stat -c %a "$fenced")" = 600 ]
    grep -Eq '^===== BEGIN UNTRUSTED CODEX FINDINGS CONTENT [0-9a-f]{32} =====$' <<<"$(head -n1 "$fenced")"
    grep -Eq '^===== END UNTRUSTED CODEX FINDINGS CONTENT [0-9a-f]{32} =====$' <<<"$(tail -n1 "$fenced")"
    for m in '**High** - x' '[P2] y' 'Low-level note'; do grep -qxF -- "$m" "$fenced"; done
  fi
  if [ "$scenario" = ran-fence-fail ]; then
    grep -qx 'findings:unavailable' "$TMP/out"
    if grep -q '^findings:file=' "$TMP/out"; then echo 'FAIL: fence failure still prints a findings file'; exit 1; fi
    rm -f "$N1_HOME/scratch"
  fi
  if [ "$scenario" = memory-unavailable ]; then
    jq -e '.comment == "saved"' "$receipt" >/dev/null
    grep -qx 'No findings.' "${receipt%.json}.md"
    [ ! -e "$N1_HOME/x" ]
  fi
  if [ "$scenario" = diff-unavailable ]; then jq -e '.reason == "diff-unavailable"' "$receipt" >/dev/null; fi
  if [ "$scenario" = failed ] || [ "$scenario" = timeout ]; then [ -f "${receipt%.json}.stderr.log" ]; fi
  printf 'PASS: %s produces a terminal branch receipt\n' "$scenario"
done

# A processed pre-push receipt satisfies PR observation in this and any other session.
observe review-test "$WT" https://github.com/example/repo/pull/43 > "$TMP/obs-done"
[ ! -s "$TMP/obs-done" ]
jq -e '.processed and .outcome == "failed"' "$receipt" >/dev/null
observe resumed-obs "$WT" https://github.com/example/repo/pull/43 > "$TMP/obs-resumed"
[ ! -s "$TMP/obs-resumed" ] && [ ! -e "$N1_HOME/review-receipts/resumed-obs" ]
printf 'PASS: a processed pre-push receipt satisfies PR observation in any session\n'

M="$TMP/multi"; mkrepo "$M" feature/multi >/dev/null
observe multi-pr "$M" $'https://github.com/example/repo/pull/1\nhttps://github.com/example/repo/pull/2' > "$TMP/multi.out"
jq -se 'length == 1 and (.[0].hookSpecificOutput.additionalContext | contains("pull/1") and contains("pull/2"))' "$TMP/multi.out" >/dev/null
printf 'PASS: multiple PRs produce one structured hook response\n'

A="$TMP/active"; mkrepo "$A" feature/active >/dev/null
observe active-stop "$A" https://github.com/example/repo/pull/46 >/dev/null
printf '{"session_id":"active-stop","stop_hook_active":true}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/active-stop"
[ ! -s "$TMP/active-stop" ]
jq -e '.reminded != true' "$N1_HOME/review-receipts/active-stop/feature_active.json" >/dev/null
printf '{"session_id":"active-stop"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/next-stop"
jq -e '.decision == "block"' "$TMP/next-stop" >/dev/null
printf 'PASS: another Stop continuation does not consume an unsent reminder\n'

F="$TMP/ftail"; mkrepo "$F" feature/ftail >/dev/null
payload=$(jq -nc --arg c "$F" '{session_id:"failed-tail",cwd:$c,hook_event_name:"PostToolUseFailure",tool_input:{command:"gh pr create && false"},error:"Exit code 1\nhttps://github.com/example/repo/pull/44"}')
printf '%s' "$payload" | bash "$ROOT/hooks/pr-review-observe.sh" > "$TMP/failed-tail"
jq -e '.outcome == "skipped" and .reason == "step-not-run"' "$N1_HOME/review-receipts/failed-tail/feature_ftail.json" >/dev/null
jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"' "$TMP/failed-tail" >/dev/null
jq -e '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("pr-review-observe.sh"))' "$ROOT/hooks/hooks.json" >/dev/null
printf 'PASS: failed command tail still observes its created PR\n'

# AC5: a PR on the active run's branch with no processed receipt (PostToolUse missed it) is caught at Stop.
unset AUTH_MODE REVIEW_MODE CODEX_OUT
printf '{}\n' > "$N1_HOME/config.json"
RS="$TMP/rs"; mkrepo "$RS" feature/T-5 >/dev/null
git -C "$RS" update-ref refs/remotes/origin/feature/T-5 HEAD
printf '{"ticketId":"T-5","runId":"r","worktreePath":"%s","branch":"feature/T-5"}\n' "$RS" > "$N1_HOME/active-run.run-stop.json"
check_run() { N1_SESSION_ID="$1" bash -c 'source "$1/lib/codex-review.sh"; n1_review_check_run' _ "$ROOT"; }
: > "${REVIEW_LOG}.list"
[ -z "$(PR_LIST_URLS= check_run run-stop)" ] && [ ! -e "$N1_HOME/review-receipts/run-stop" ]
printf 'PASS: a pushed branch without a PR is not flagged\n'
export PR_LIST_URLS=https://github.com/example/repo/pull/50
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"run-stop"}' > "$TMP/run-stop"
jq -e '.decision == "block" and (.reason | contains("feature/T-5"))' "$TMP/run-stop" >/dev/null
jq -e '.branch == "feature/T-5" and .outcome == "skipped" and .reason == "step-not-run" and (.processed | not)' "$N1_HOME/review-receipts/run-stop/feature_T-5.json" >/dev/null
grep -q -- '--head feature/T-5' "${REVIEW_LOG}.list"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"run-stop"}' > "$TMP/run-stop-2"
[ ! -s "$TMP/run-stop-2" ]
printf 'PASS: Stop records and blocks once for an unreceipted branch with a PR\n'
[ "$(check_run run-stop)" = "$PR_LIST_URLS" ]
N1_SESSION_ID=run-stop bash -c 'source "$1/lib/codex-review.sh"; n1_review_record feature/T-5 ran "" true' _ "$ROOT"
[ -z "$(check_run run-stop)" ]
printf 'PASS: run check lists the PR until a processed branch receipt exists\n'
printf '{"ticketId":"T-5","runId":"r","worktreePath":"%s","branch":"feature/T-5"}\n' "$RS" > "$N1_HOME/active-run.resumed.json"
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"resumed"}' > "$TMP/resumed"
[ ! -s "$TMP/resumed" ]
[ ! -e "$N1_HOME/review-receipts/resumed" ]
printf 'PASS: a processed receipt from another session satisfies the run check\n'
printf '{"ticketId":"T-5","runId":"r","worktreePath":"%s","branch":"feature/T-5"}\n' "$RS" > "$N1_HOME/active-run.mixed.json"
rm -rf "$N1_HOME/review-receipts/run-stop"
mkdir -p "$N1_HOME/review-receipts/other-a" "$N1_HOME/review-receipts/other-b"
printf '{"branch":"feature/T-5","processed":false}\n' > "$N1_HOME/review-receipts/other-a/feature_T-5.json"
printf '{"branch":"feature/T-5","outcome":"ran","processed":true}\n' > "$N1_HOME/review-receipts/other-b/feature_T-5.json"
[ -z "$(check_run mixed)" ]
bash "$ROOT/hooks/pr-review-stop.sh" <<<'{"session_id":"mixed"}' > "$TMP/mixed"
[ ! -s "$TMP/mixed" ]
printf 'PASS: any processed receipt wins over an unprocessed one from another session\n'
rm -rf "$N1_HOME/review-receipts"; mkdir -p "$N1_HOME/review-receipts/old"
printf '{"branch":"feature/T-5","processed":true}\n' > "$N1_HOME/review-receipts/old/feature_T-5.json"
[ -z "$(N1_STATE_DIR="$TMP/empty-state" check_run mixed)" ]
printf 'PASS: a legacy per-project processed receipt (no outcome field) satisfies the run check\n'
: > "${REVIEW_LOG}.list"
N1_SESSION_ID=mixed bash -c 'command() { [ "${2:-}" = timeout ] && return 1; builtin command "$@"; }; source "$1/lib/codex-review.sh"; n1_review_check_run' _ "$ROOT" >/dev/null
[ ! -s "${REVIEW_LOG}.list" ]
printf 'PASS: no timeout binary skips the PR lookup instead of running gh unbounded\n'
git -C "$RS" update-ref -d refs/remotes/origin/feature/T-5
printf '{"ticketId":"T-5","runId":"r","worktreePath":"%s","branch":"feature/T-5"}\n' "$RS" > "$N1_HOME/active-run.unpushed.json"
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
# N1-203: receipts resolve to one location regardless of cwd (hook in repo A, runner in repo B)
(
  unset N1_HOME N1_SESSION_ID N1_STATE_DIR AUTH_MODE REVIEW_MODE CODEX_OUT PR_LIST_URLS
  export HOME="$TMP/h" CLAUDE_CODE_SESSION_ID=xrepo-s
  for r in a b; do
    mkdir -p "$HOME/.n1/proj-$r"
    mkrepo "$TMP/repo-$r" feature/x > "$TMP/base-$r"
    git -C "$TMP/repo-$r" remote add origin "https://github.com/example/proj-$r.git"
  done
  (cd "$TMP/repo-a" && observe xrepo-s "$TMP/repo-a" https://github.com/example/repo/pull/77 >/dev/null)
  (cd "$TMP/repo-a" && printf '{"session_id":"xrepo-s"}' | bash "$ROOT/hooks/pr-review-stop.sh" | jq -e '.decision == "block"' >/dev/null)
  f="$HOME/.n1/review-receipts/xrepo-s/feature_x.json"; jq 'del(.reminded)' "$f" > "$f.t" && mv "$f.t" "$f"
  (cd "$TMP/repo-b" && N1_CODEX_AUTH_TIMEOUT=0.1 N1_CROSS_HOST_REVIEW_TIMEOUT=1 bash "$ROOT/scripts/codex-pr-review.sh" "$(cat "$TMP/base-b")" T-9 >/dev/null)
  jq -e '.outcome == "ran" and .processed' "$f" >/dev/null
  (cd "$TMP/repo-a" && printf '{"session_id":"xrepo-s"}' | bash "$ROOT/hooks/pr-review-stop.sh" > "$TMP/xstop")
  [ ! -s "$TMP/xstop" ]
  [ -z "$(find "$HOME/.n1/proj-a" "$HOME/.n1/proj-b" -name review-receipts)" ]
)
printf 'PASS: hook in repo A, runner in repo B and Stop in repo A share one receipt location\n'
