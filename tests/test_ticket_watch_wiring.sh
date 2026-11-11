#!/usr/bin/env bash
# N1-89: ticket-watch procedure keeps its guards, and the orchestrator/init/docs reference it (capture: N1-314).
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=skills/n1-start/procedures/ticket-watch.md
R=skills/n1-start/procedures/ticket-watch-react.md
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
nocheck() { # <label> <extended-regex> <file>: the pattern must be absent
    if grep -qE "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
check "SKILL.md check-point pointer" "before Step 10 \(PR creation\) run .*n1_tw_check_http .*procedures/ticket-watch\.md § Check\`" skills/n1-start/SKILL.md
nocheck "SKILL.md check-point drops 11b" "Check\` before.*11b" skills/n1-start/SKILL.md
check "analysis seeds the watch" "procedures/ticket-watch\.md § Seed" skills/n1-start/steps/analysis.md
check "procedure has Seed" "^## § Seed" "$P"
check "procedure has Check" "^## § Check" "$P"
check "Check fetches issue and first page in one turn" 'CHANGED since <SINCE>; \.\.\.`: in one turn, call `mcp__<WATCH_MCP>__jcm_getIssue`' "$P"
check "Check reads the unchanged line" '`ticket-watch: unchanged`: continue' "$P"
check "Check reads the next-page line" '`ticket-watch: fetch next changelog page since <S>`' "$P"
check "Check reads the own-only line" '`ticket-watch: no external change`' "$P"
check "digest line goes to React" '`ticket-watch: digest .*ticket-watch-react\.md.*§ React' "$P"
check "single fallback statement" '^\*\*Fallback \(the only one\):\*\* .*no `ticket-watch:` line' "$P"
check "hook emits additionalContext" 'additionalContext' hooks/ticket-watch-capture.sh
check "procedure falls back on TW_MISSING" "TW_MISSING" "$P"
check "probe read guarded by n1_tw_need" 'n1_tw_need "\$M/\.tw-probe\.json"' "$P"
check "delta read guarded by n1_tw_need" 'n1_tw_need "\$M/\.tw-issue\.json" "\$M/\.tw-log-1\.json"' "$P"
check "Seed starts with the HTTP call" 'n1_tw_seed_http "\$ID"' "$P"
check "Check starts with the HTTP call" 'n1_tw_check_http "\$ID"' "$P"
check "model path only on TW_FALLBACK" 'Only on `TW_FALLBACK <reason>`' "$P"
check "architecture documents the HTTP check" "n1_tw_check_http" references/architecture.md
check "architecture documents capture hook" "ticket-watch-capture\.sh" references/architecture.md
check "procedure has React" "^## § React" "$R"
check "procedure has Replan" "^## § Replan" "$R"
check "Check hands off to react file" "ticket-watch-react\.md" "$P"
check "Jira getChangelog mapping in n1-init" "\"getChangelog\": \"jcm_getIssueChangelog\"" skills/n1-init/steps/03-tracker.md
check "YouTrack getChangelog explicitly unmapped" "YouTrack.*getChangelog.*not mapped" skills/n1-init/steps/03-tracker.md
check "architecture documents the watch" "procedures/ticket-watch\.md" references/architecture.md
check "host saves the current user for the seed" 'before the cursor exists it also saves the `jcm_getCurrentUser` response to `M/\.tw-me\.json`' "$P"
nocheck "Seed no longer writes .tw-me.json itself" 'Write the raw getCurrentUser response|always yours to write' "$P"
check "architecture documents getCurrentUser capture" 'saves the `jcm_getCurrentUser` response to `\.tw-me\.json`' references/architecture.md
exit "$FAIL"
