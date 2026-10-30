#!/usr/bin/env bash
# N1-102: the shared follow-up filing procedure keeps its guards, and every proposal site references it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/followup-filing.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

check "procedure gates on qualityEscalations" "n1_autonomy_val 'qualityEscalations'" "$P"
check "candidates never pass through a shell command" 'never through a shell command' "$P"
check "reuses duplicate-check in create context" 'duplicate-check\.md` § Check with `CONTEXT=create`' "$P"
check "marker written only after create succeeds" 'only after the create call succeeds' "$P"
check "File passes SELF_ID=<ID> to duplicate-check" 'SELF_ID=<ID>' "$P"
check "Append sanitizes CR, LF and pipe" 'replace CR, LF and `\|` with a space' "$P"
check "Gate 3 report validates keys" 'whose KEY matches the key regex' "$P"
check "keys validated before use" '\^\[A-Z\]\[A-Z0-9_\]\*-\[0-9\]\+\$' "$P"
check "open candidate bounded by next heading and positively anchored" 'matching `\^- ` that is not a marked line.*bounded by the next `\^## ` heading or EOF' "$P"
check "title strips all leading [ (unforgeable marker)" 'strip all leading `\[` characters' "$P"
check "Append inserts inside the section" 'at the end of the `## Follow-ups` section, before the next' "$P"
check "security candidates flagged" 'Security-relevant:' "$P"
check "pending marker written before create" 'rewrite the line as `- \[pending\]' "$P"
check "pending reconciled by tracker search on resume" 'pending` line met on resume.*search the tracker' "$P"
check "pending reconcile runs for queue children" 'pending` reconcile below still runs' "$P"
check "pending counts against the cap" 'count `pending`, `unlinked`' "$P"
check "unlinked marker retried on resume" 'leave the line `unlinked` \(a resume retries it\)' "$P"
check "done marker only after link succeeds" 'Only after the link succeeds' "$P"
check "report never lists pending as a key" '`- \[pending\]` is never a key' "$P"
check "report strips unlinked" 'strip ` unlinked`' "$P"

check "review fix appends deferrals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/steps/fix.md
check "QA fix appends deferrals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/steps/qa.md
check "finalize appends its own proposals (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-start/procedures/finalize.md
check "finalize worker runs File before Gate 3" 'followup-filing\.md` § File' agents/tail-worker.md
check "Gate 3 template carries Follow-ups line" 'Follow-ups: <KEY>' skills/n1-start/procedures/output-gates.md

check "Codex step appends human-review items (auto-accept only)" 'auto-accept.*followup-filing\.md` § Append' skills/n1-pr/steps/03-codex-review.md

exit $FAIL
