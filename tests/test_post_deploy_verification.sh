#!/usr/bin/env bash
# Textual wiring checks for post-deploy verification setup and public contract.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
check() {
    if grep -qE "$2" "$3"; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1"; FAIL=$((FAIL + 1))
    fi
}
check_absent() {
    if grep -qE "$2" "$3"; then
        echo "FAIL: $1"; FAIL=$((FAIL + 1))
    else
        echo "PASS: $1"; PASS=$((PASS + 1))
    fi
}
check_fixed() {
    if grep -qF "$2" "$3"; then
        echo "PASS: $1"; PASS=$((PASS + 1))
    else
        echo "FAIL: $1"; FAIL=$((FAIL + 1))
    fi
}

INIT_PREREQ=skills/n1-init/steps/01-prerequisites.md
INIT_FINISH=skills/n1-init/steps/09-finish-release.md
INIT_CONFIG=skills/n1-init/steps/13-write-config.md
INIT_CONFIRM=skills/n1-init/steps/15-confirm.md
FINISH=skills/n1-finish/SKILL.md
ARCH=references/architecture.md
README=README.md
DEPLOY=skills/n1-finish/steps/03-deploy.md
CLOSE=skills/n1-finish/steps/04-close-ticket.md
CLEANUP=skills/n1-finish/steps/06-cleanup.md

check "fresh config writes disabled nested default" '"postDeployVerification"[[:space:]]*:[[:space:]]*\{' "$INIT_CONFIG"
if awk '
    /"postDeployVerification"[[:space:]]*:/ { in_verification = 1; next }
    in_verification && /"enabled"[[:space:]]*:[[:space:]]*false/ { found = 1; exit }
    in_verification && /^[[:space:]]*}/ { in_verification = 0 }
    END { exit !found }
' "$INIT_CONFIG"; then
    echo "PASS: fresh config disables post-deploy verification"
    PASS=$((PASS + 1))
else
    echo "FAIL: fresh config disables post-deploy verification"
    FAIL=$((FAIL + 1))
fi
check "init asks post-deploy verification separately from local testing" 'post-deploy verification' "$INIT_FINISH"
check "opt-in is offered only after deploy watch" 'If deploy watch is Yes.*post-deploy verification' "$INIT_FINISH"
check_fixed "reconfiguration offers opt-in only with deploy watch" 'When `finishWork.deployWatch.enabled` is `true`, offer the **Post-deploy verification** questions above' "$INIT_FINISH"
check "reconfiguration disables verification without deploy watch" 'When deploy watch is disabled or absent.*postDeployVerification.*enabled.*false' "$INIT_FINISH"
check "enabled setup creates dev-access template" 'dev-access\.md' "$INIT_FINISH"
check "dev-access template records URL or entry point" 'URL.*entry point|entry point.*URL' "$INIT_FINISH"
check "dev-access template requires non-secret setup" 'Non-secret' "$INIT_FINISH"
check_fixed "nested-key gap is detected" 'finishWork.postDeployVerification.enabled' "$INIT_PREREQ"
check "declined upgrade preserves legacy fallback" 'legacy fallback' "$INIT_PREREQ"
check "confirmation reports setting" 'Post-deploy verification:' "$INIT_CONFIRM"
check "confirmation reports dev-access creation" 'dev-access\.md' "$INIT_CONFIRM"
check "finish contract states explicit false precedence" 'explicit.*false.*legacy smoke|legacy smoke.*explicit.*false' "$FINISH"
check "finish contract states successful-deploy dispatch" 'successful deployment|deploy.*succeeds' "$FINISH"
check "finish contract names verifier artifact inputs" 'post-deploy-verification\.md.*ticket\.md|ticket\.md.*post-deploy-verification\.md' "$FINISH"
check "architecture documents nested verification gate" 'postDeployVerification\.enabled' "$ARCH"
check "architecture documents informational failure" 'informational|does not block.*close|does not prevent.*close' "$ARCH"
check "README counts post-deploy verifier" 'post-deploy-verifier' "$README"

# Finish lifecycle wiring. These are deliberately textual: the verifier itself
# is a persona contract, while this test protects the controller hand-offs.
check "Step 3b sources config helper" 'source "\$N1_ROOT/lib/config\.sh"' "$DEPLOY"
check "Step 3b gates through post-deploy helper" 'n1_post_deploy_verification_enabled' "$DEPLOY"
if awk '/^## Steps/{exit} /POST_DEPLOY_VERIFICATION_ARTIFACT=false/{found=1} END { exit !found }' "$FINISH"; then
    echo "PASS: finish entry initializes verification artifact guard before routes"
    PASS=$((PASS + 1))
else
    echo "FAIL: finish entry initializes verification artifact guard before routes"
    FAIL=$((FAIL + 1))
fi
check_absent "deploy step does not initialize verification artifact guard" 'POST_DEPLOY_VERIFICATION_ARTIFACT=false' "$DEPLOY"
check "verification dispatch requires actual successful deployment" 'All `conclusion: success`.*deploy status `succeeded`' "$DEPLOY"
check "neutral and skipped deployments do not dispatch verification" 'neutral.*skipped.*non-`success`.*do not dispatch' "$DEPLOY"
check "cancelled deployments are terminal without verification" 'cancelled.*not deployed.*do not dispatch|cancelled.*do not dispatch.*not deployed' "$DEPLOY"
check "failed deploy does not dispatch verification" 'failed.*STOP|STOP.*failed' "$DEPLOY"
check "timed out deploy does not dispatch verification" 'Timeout.*STOP|STOP.*Timeout' "$DEPLOY"
check "no-run path does not dispatch verification" 'none triggered.*Step 4' "$DEPLOY"
check "local merge does not dispatch verification" 'Local-merge.*skip.*entire file' "$DEPLOY"
check "disabled gate writes canonical skipped rows" 'SKIPPED \(disabled\).*every acceptance criterion|every acceptance criterion.*SKIPPED \(disabled\)' "$DEPLOY"
check "deployment captures canonical PR diff" 'post-deploy-pr\.diff' "$DEPLOY"
check "dispatch passes all six canonical paths" 'ticket\.md.*analysis\.md.*local-test-plan\.md.*post-deploy-pr\.diff.*config\.json.*dev-access\.md' "$DEPLOY"
check "legacy smoke endpoint stays verifier input" 'smokeEndpoint' "$DEPLOY"
check "legacy smoke commands stay verifier input" 'smokeTests' "$DEPLOY"
check "missing dev access does not suppress legacy smoke" 'dev-access\.md.*smoke|smoke.*dev-access\.md' "$DEPLOY"
check "missing diff writes skipped fallback" 'diff.*SKIPPED|SKIPPED.*diff' "$DEPLOY"
check "missing verifier artifact writes skipped fallback" 'artifact.*SKIPPED|SKIPPED.*artifact' "$DEPLOY"
check "prior artifact is cleared before verifier dispatch" 'rm -f "\$VERIFICATION_PATH"' "$DEPLOY"
check "only current invocation marks artifact available" 'POST_DEPLOY_VERIFICATION_ARTIFACT=true' "$DEPLOY"
check "tracker comment renders criterion table" 'verification.*table|table.*verification' "$CLOSE"
check "tracker skips stale verification artifact" 'POST_DEPLOY_VERIFICATION_ARTIFACT=true' "$CLOSE"
check "tracker idempotency uses full rendered comment" 'identical.*full.*comment|full.*rendered.*comment' "$CLOSE"
check "cleanup persists criterion table in Finish" '## Finish.*verification|verification.*## Finish' "$CLEANUP"
check "final report prints criterion table" 'Verification.*table|table.*Verification' "$CLEANUP"
check "cleanup skips stale verification artifact" 'POST_DEPLOY_VERIFICATION_ARTIFACT=true' "$CLEANUP"
check "verification failure still closes ticket" 'FAIL.*clos|clos.*FAIL' "$DEPLOY"
check "verification skipped still closes ticket" 'SKIPPED.*clos|clos.*SKIPPED' "$DEPLOY"
check "verifier inherits dynamic observability tools" 'tools intentionally omitted.*observability MCP' agents/post-deploy-verifier.md
check "verifier keeps read-only boundary with artifact exception" 'only to read.*read-only.*sole write' agents/post-deploy-verifier.md
check "verifier uses investigation effort" '^effort: medium$' agents/post-deploy-verifier.md

# N1-111: deploy watch is one bounded blocking wait per call, never one model turn per poll.
MERGE=skills/n1-finish/steps/02-merge.md
check_fixed "deploy watch uses the poll helper for every event" "n1_wait_release_runs <sha> <grace> <remaining-minutes> '<workflowName>' any" "$DEPLOY"
check_absent "deploy watch has no hand-polled sleep loop" 'sleep 30' "$DEPLOY"
check_fixed "deploy watch must not be backgrounded" 'Never background it' "$DEPLOY"
check_fixed "deploy watch forbids scheduled wakeups and per-poll turns" 'Do not use scheduled wakeups or one model turn per poll' "$DEPLOY"
check "unreachable gh stops with the re-run message" 'unknown.*re-run `/n1:n1-finish`' "$DEPLOY"
check_fixed "merge wait forbids scheduled wakeups" 'never use scheduled wakeups' "$MERGE"
check_fixed "deploy watch runs with the maximum command timeout" 'maximum command timeout (600000 ms)' "$DEPLOY"
check_fixed "merge wait runs with the maximum command timeout" 'maximum command timeout (600000 ms)' "$MERGE"
if grep -rqF ScheduleWakeup skills/n1-finish; then
    echo "FAIL: n1-finish names no wakeup tool"; FAIL=$((FAIL + 1))
else
    echo "PASS: n1-finish names no wakeup tool"; PASS=$((PASS + 1))
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
