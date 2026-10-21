#!/usr/bin/env bash
# N1-102: the shared follow-up filing procedure keeps its guards, and every proposal site references it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/followup-filing.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "procedure has Append section" '^## § Append' "$P"
check "procedure has File section" '^## § File' "$P"
check "procedure gates on qualityEscalations" "n1_autonomy_val 'qualityEscalations'" "$P"
check "procedure states ask mode is unchanged" 'Ask mode .* never appends or files' "$P"
check "candidates never pass through a shell command" 'never through a shell command' "$P"
check "candidate line format" '`- <title, ≤80 chars> \| <one-line reason' "$P"
check "fixed cap of 5 per run" 'at most 5 per run' "$P"
check "reuses duplicate-check in create context" 'duplicate-check\.md` § Check with `CONTEXT=create`' "$P"
check "duplicate hit is not recreated" '\[<HIT_ID> existing\]' "$P"
check "applies ticket-scope rule" 'ticket-scope\.md` § Free-form creation' "$P"
check "create op from operations.createIssue" 'tracker\.operations\.createIssue' "$P"
check "filed marker format" '`- \[<KEY>\] <title>' "$P"
check "marker written only after create succeeds" 'only after the create call succeeds' "$P"
check "keys validated before use" '\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\$' "$P"
check "link op from operations.linkIssues" 'tracker\.operations\.linkIssues' "$P"
check "YouTrack Relates mapped to relates to" 'map `Relates` .+ `relates to`' "$P"
check "Jira link payload includes cloudId" 'cloudId`, `inwardIssue' "$P"
check "link failure warns" 'Could not link <KEY> .+ <ID>:' "$P"
check "create failure warns and continues" 'Warning: Follow-up not filed' "$P"
check "one comment via operations.addComment" 'tracker\.operations\.addComment' "$P"
check "comment only when this run marked a line" 'only when this run marked at least one line' "$P"
check "Gate 3 line format" 'Follow-ups: <KEY>' "$P"
check "procedure never blocks" 'Never blocks' "$P"
check "architecture.md documents the procedure" 'references/followup-filing\.md' references/architecture.md

check "review fix appends deferrals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/steps/fix.md
check "review fix tags source review" 'source `review`' skills/n1-start/steps/fix.md
check "QA fix appends deferrals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/steps/qa.md
check "QA fix tags source qa" 'source `qa`' skills/n1-start/steps/qa.md
check "finalize appends its own proposals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/procedures/finalize.md
check "finalize runs File before Gate 3" 'followup-filing\.md` § File' skills/n1-start/procedures/finalize.md
check "Gate 3 template carries Follow-ups line" 'Follow-ups: <KEY>' skills/n1-start/procedures/output-gates.md
check "Gate 3 auto-accept never offers to file follow-ups" 'auto-accept.*file follow-ups' skills/n1-start/procedures/output-gates.md

check "Codex step appends human-review items (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-pr/steps/03-codex-review.md
check "Codex step tags source codex" 'source `codex`' skills/n1-pr/steps/03-codex-review.md
check "Codex step auto-accept never offers to file follow-ups" 'auto-accept.*file follow-ups' skills/n1-pr/steps/03-codex-review.md

exit $FAIL
