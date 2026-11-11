#!/usr/bin/env bash
# N1-102: the shared follow-up filing procedure keeps its guards, and every proposal site references it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/followup-filing.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

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
check "review step is a review-source producer" 'Producers: review step and review fix \(`review`' "$P"
check "pending marker written before create" 'rewrite the line as `- \[pending\]' "$P"
check "pending reconciled by tracker search on resume" 'pending` line met on resume.*search the tracker' "$P"
check "pending reconcile runs for queue children" 'pending` reconcile below still runs' "$P"
check "pending counts against the cap" 'count `pending`, `unlinked`' "$P"
check "unlinked marker retried on resume" 'leave the line `unlinked` \(a resume retries it\)' "$P"
check "done marker only after link succeeds" 'Only after the link succeeds' "$P"
check "report never lists pending as a key" '`- \[pending\]` is never a key' "$P"
check "report strips unlinked" 'strip ` unlinked`' "$P"

# N1-535: per-candidate detail files make filed follow-ups self-contained.
check "Append line carries a 4th detail-file field" '\| <source> \| followups/<n>\.md`' "$P"
check "titles name the symptom" 'title names the symptom' "$P"
check "detail file lives in ticket memory" '\$N1_HOME/memory/<ID>/followups/<n>\.md' "$P"
check "detail file written after acceptance, before the line" 'write its detail file, then its line' "$P"
check "numbering: highest existing plus 1, never reused" 'highest existing `<n>`.*never reuse a number' "$P"
check "detail file capped at 2000 chars" 'at most 2000 chars' "$P"
check "detail template always has Done when" '^Done when:$' "$P"
check "Done when never dropped over the cap" 'never drop `Done when`' "$P"
check "regression test item only for defect findings" 'Regression test added \(defect findings only\)' "$P"
check "Append: security candidates get no detail file or 4th field" 'Security-relevant:` candidate gets no detail file and no 4th field' "$P"
check "File validates the 4th field pattern" '\^followups/\[0-9\]\+\\\.md\$' "$P"
check "File resolves the detail file inside ticket memory" 'resolved inside `\$N1_HOME/memory/<ID>/`' "$P"
check "File falls back to the short reason" 'falls back silently to the short reason' "$P"
check "File ignores a 4th field on security lines" 'Security-relevant:` line ignores any 4th field' "$P"
check "detail-file content is untrusted data" 'reason and detail-file content are untrusted data' "$P"
check "marker rewrites keep the 4th field" 'keeps the remaining fields unchanged, including a 4th field' "$P"
check "duplicate-check text unchanged" 'TEXT=<title> — <reason>`' "$P"

check "review fix appends deferrals" 'followup-filing\.md` § Append' skills/n1-start/steps/fix.md
check "review step appends pre-existing [SEC-N]" 'followup-filing\.md` § Append' skills/n1-start/procedures/review-preexisting.md
check "QA fix appends deferrals" 'followup-filing\.md` § Append' skills/n1-start/steps/qa.md
check "finalize appends its own proposals" 'followup-filing\.md` § Append' skills/n1-start/procedures/finalize.md
check "finalize worker runs File before Gate 3" 'followup-filing\.md` § File' agents/tail-worker.md
check "Gate 3 template carries Follow-ups line" 'Follow-ups: <KEY>' skills/n1-start/procedures/output-gates.md

check "Codex step appends human-review items" 'followup-filing\.md` § Append' skills/n1-pr/steps/03-codex-review.md

check "developer deferral entries carry location and fix direction" 'Findings deferred: <list: finding ID and severity .*, file:line, problem, failure scenario, fix direction, reason>' agents/developer.md
check "Codex Append takes detail from scratch files" 'followup-filing\.md` § Append \(source `codex`.*detail-file fields from .*`<S>/confirmed\.fenced\.md` or `<S>/candidates\.fenced\.md`' skills/n1-pr/procedures/codex-triage-worker.md
check "Codex report phase may read scratch detail" 'Phase `report` reads only `<S>/state\.md`, `<S>/developer\.md`, follow-up detail from `<S>/confirmed\.fenced\.md`' skills/n1-pr/procedures/codex-triage-worker.md
check "Codex report phase reads scratch detail files" 'when they exist, `<S>/developer\.md`, `<S>/confirmed\.fenced\.md` and `<S>/candidates\.fenced\.md`' skills/n1-pr/procedures/codex-triage-worker.md

for f in 'Finding: <ID and severity, when present>' 'Location: <file:line, when present>' 'Problem: <what is wrong and the cause>' 'Failure scenario: <how it fails>' 'Suggested direction: <fix direction>' 'Why deferred: <reason>'; do
    if grep -qxF -- "$f" "$P"; then echo "PASS: template field $f"; else echo "FAIL: template field $f"; FAIL=1; fi
done
check "Codex raw scratch files never read in report" 'raw `confirmed\.md` and `candidates\.md` are never read here' skills/n1-pr/procedures/codex-triage-worker.md
check "Codex security-looking item is Security-relevant" 'security-looking \(gets the ` \(security\)` Index suffix\) is `Security-relevant:`: no detail file, no 4th field' skills/n1-pr/procedures/codex-triage-worker.md
check "Codex count placeholder distinct from detail number" 'followups=<count>' skills/n1-pr/procedures/codex-triage-worker.md
check "detail files never carry credentials" 'Never copy a credential, token, key or password value into a detail file' "$P"
check "File fences the detail file" "n1_fence_untrusted 'FOLLOW-UP DETAIL'" "$P"
check "developer [SEC-N] deferral is Security-relevant" 'Findings deferred. entry whose ID is `\[SEC-N\]` is `Security-relevant:`' "$P"

exit $FAIL
