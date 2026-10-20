#!/usr/bin/env bash
# tests/test_config_keys.sh -- N1-113: removed config keys have no reader/writer outside the
# n1-init prune list; n1_config_val never receives a literal 2nd arg (it is a FILE, not a default).
# Run: bash tests/test_config_keys.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

HITS=$(grep -rnE "n1_config_val +['\"][^'\"]+['\"] +'" skills agents lib hooks scripts || true)
if [ -z "$HITS" ]; then ok "n1_config_val 2nd arg is never a literal"; else no "n1_config_val literal 2nd arg (use \${VAR:-default}):"; echo "$HITS"; fi

PRUNE=skills/n1-init/steps/01-prerequisites.md
DEAD=(
  qa.blockUntestedFeatures
  qa.verifyGate
  BLOCK_UNTESTED
  estimation.enabled
  .estimation.
  '"estimation"'
  n1-estimate
  steps/estimation.md
  07-estimation
  gate_estimation
  estimation_enabled
  worktree.mode
  worktree.cleanup
  BRANCH_FLAG
  '[--branch]'
  'Branch in current checkout'
  'Ensure Working Branch'
  'kept (manual)'
  telemetry.enabled
  telem_enabled
  n1_finish_enabled
  finishWork.enabled
  finishWork.mergeOnFinish
  waitForMergeMinutes
  closeTicket
  gate_finish
  deployWatch.enabled
  deployWatch.timeoutMinutes
  release.deployWatch
  testCoverage.tier
  review.minCleanPasses
  minCleanPasses
  ciChecks.enabled
  ciChecks.maxFixAttempts
  ciChecks.confidenceThreshold
  n1_ci_checks_val
  escalation.alwaysAskOn
  '.escalation.${key}'
  planReview.reviewPlan
  n1_plan_review_enabled
  n1_test_coverage_tier
  n1_review_min_clean_passes
  maxSnapshotAge
  analysisCache.ttl
  analysisCache.neutralThreshold
  tagPrefix
  trackerRelease.moveTickets
  trackerRelease.createVersion
  trackerRelease.setFixVersion
  trackerRelease.enabled
  tailChain
  confirmedAt
  rules.json
  gate_ci
  rules.enabled
  rules.location
  '.rules)'
  story.enabled
  story.opusFromSize
  codex.enabled
  codexReview.enabled
  tracker.statuses.backlog
)
for k in "${DEAD[@]}"; do
  HITS=$(grep -rnF -- "$k" skills lib hooks scripts defaults pipeline.json references README.md CLAUDE.md | grep -v "^$PRUNE:" || true)
  if [ -z "$HITS" ]; then ok "removed: $k"; else no "still referenced: $k"; echo "$HITS"; fi
done

# Prune list: both DEAD= sites identical; removes every removed key, keeps live keys, drops emptied parents.
mapfile -t SITES < <(grep -E "^ *DEAD='" "$PRUNE" | sed "s/^ *//")
if [ "${#SITES[@]}" = 2 ] && [ "${SITES[0]}" = "${SITES[1]}" ]; then ok "prune list identical at both sites"; else no "prune list sites differ or missing (${#SITES[@]})"; fi
eval "${SITES[0]}"
IN='{"telemetry":{"enabled":true},"worktree":{"cleanup":"after-merge","mode":"external","setup":"npm ci"},"finishWork":{"enabled":true,"mergeOnFinish":false,"waitForMergeMinutes":10,"closeTicket":true,"mergeMethod":"squash","deployWatch":{"enabled":true,"timeoutMinutes":30,"workflowName":"deploy.yml"}},"qa":{"blockUntestedFeatures":false,"maxFixAttempts":3},"estimation":{"enabled":true},"rules":{"enabled":true},"codex":{"enabled":true},"release":{"enabled":true,"tagPrefix":"v","deployWatch":{"enabled":true},"trackerRelease":{"moveTickets":true,"createVersion":true,"setFixVersion":true}},"relatedProjects":{"maxSnapshotAge":"72h","projects":[{"slug":"a","confirmedAt":"x"}]},"queue":{"mergeOnFinish":true},"autonomy":{"mode":"hands-off","tailChain":"suggest"}}'
WANT='{"worktree":{"setup":"npm ci"},"finishWork":{"mergeMethod":"squash","deployWatch":{"workflowName":"deploy.yml"}},"qa":{"maxFixAttempts":3},"release":{"enabled":true},"relatedProjects":{"projects":[{"slug":"a"}]},"queue":{"mergeOnFinish":true},"autonomy":{"mode":"hands-off"}}'
GOT=$(jq -cS "$DEAD" <<<"$IN"); EXP=$(jq -cS . <<<"$WANT")
if [ "$GOT" = "$EXP" ]; then ok "prune removes stopgaps, keeps live keys"; else no "prune result: $GOT"; fi
if [ "$(jq -cS "$DEAD" <<<"$GOT")" = "$GOT" ]; then ok "prune idempotent"; else no "prune not idempotent"; fi
# Emptied Expected-Config-Keys sections stay present as {} (else n1-init re-asks their setup); {} stays {}.
GOT2=$(jq -cS "$DEAD" <<<'{"finishWork":{"enabled":true,"deployWatch":{"enabled":true}},"autonomy":{"tailChain":"suggest"},"telemetry":{"enabled":true}}')
if [ "$GOT2" = '{"autonomy":{},"finishWork":{}}' ]; then ok "prune keeps emptied expected sections, drops telemetry"; else no "prune emptied sections: $GOT2"; fi
if [ "$(jq -c "$DEAD" <<<'{}')" = '{}' ]; then ok "prune of {} is {}"; else no "prune of {}"; fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
