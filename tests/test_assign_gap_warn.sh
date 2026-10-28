#!/usr/bin/env bash
# Assign-to-creator gap warning helper, skill wiring, and n1-init backfill.
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/config.sh

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { # <label> <extended-regex> <file>
    if grep -qE "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1"; fi
}
mk() { printf '%s' "$1" > "$N1_HOME/config.json"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"; mkdir -p "$N1_HOME"

# ---- helper: silent cases ----
mk '{"tracker":{"type":"jira","operations":{"getCurrentUser":"atlassianUserInfo","assign":"editJiraIssue"}}}'
[ -z "$(n1_assign_gap_warn)" ] && pass "silent when both ops present" || fail "silent when both ops present"

mk '{"tracker":{"type":"jira","assignToCreator":false,"operations":{}}}'
[ -z "$(n1_assign_gap_warn)" ] && pass "silent when assignToCreator=false" || fail "silent when assignToCreator=false"

mk '{"tracker":{"type":"none","operations":{}}}'
[ -z "$(n1_assign_gap_warn)" ] && pass "silent when tracker type none" || fail "silent when tracker type none"

mk '{}'
[ -z "$(n1_assign_gap_warn)" ] && pass "silent when no tracker configured" || fail "silent when no tracker configured"

rm -f "$N1_HOME/config.json"
[ -z "$(n1_assign_gap_warn)" ] && pass "silent when config missing" || fail "silent when config missing"
n1_assign_gap_warn >/dev/null; [ $? -eq 0 ] && pass "returns 0 when config missing" || fail "returns 0 when config missing"

# ---- helper: warning cases ----
mk '{"tracker":{"type":"jira","operations":{"assign":"editJiraIssue"}}}'
out=$(n1_assign_gap_warn)
case "$out" in "Warning: tracker.assignToCreator is on but config lacks tracker.operations.getCurrentUser; "*) pass "warns for missing getCurrentUser only (absent assignToCreator counts as on)";; *) fail "warns for missing getCurrentUser only: $out";; esac

mk '{"tracker":{"type":"youtrack","assignToCreator":true,"operations":{"getCurrentUser":"get_current_user"}}}'
out=$(n1_assign_gap_warn)
case "$out" in *"tracker.operations.assign; "*) pass "warns for missing assign only";; *) fail "warns for missing assign only: $out";; esac

mk '{"tracker":{"type":"jira","operations":{"getCurrentUser":"","assign":""}}}'
out=$(n1_assign_gap_warn)
case "$out" in *"tracker.operations.getCurrentUser and assign; "*) pass "warns for both (empty strings count as missing)";; *) fail "warns for both: $out";; esac
case "$out" in *"/n1:n1-init"*"set tracker.assignToCreator to false."*) pass "warning names the fix";; *) fail "warning names the fix: $out";; esac
[ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && pass "warning is a single line" || fail "warning is a single line"

# ---- wiring: skills call the helper, wording lives only in lib/config.sh ----
check "n1-start ticket step calls helper" "n1_assign_gap_warn" skills/n1-start/steps/ticket.md
check "n1-ticket compose calls helper" "n1_assign_gap_warn" skills/n1-ticket/steps/01-compose.md
check "n1-story collect calls helper" "n1_assign_gap_warn" skills/n1-story/steps/01-collect.md
check "n1-ticket Step 8 notes warning already shown" "warning already shown at compose" skills/n1-ticket/steps/02-create.md
check "n1-story story-assign notes warning already shown" "warning already shown at collect" skills/n1-story/steps/02-compose.md
# the "never steal" guard stays in n1-start
check "n1-start ticket step keeps existing-assignee guard" "never steal from an existing assignee" skills/n1-start/steps/ticket.md
check "n1-start ticket step guard still skips on empty ops" "\`GET_USER_OP\` empty, \`ASSIGN_OP\` empty" skills/n1-start/steps/ticket.md

# ---- n1-init gap entry ----
G=skills/n1-init/steps/01-prerequisites.md
check "n1-init gap entry present" "Gap: .*getCurrentUser.*assign.* missing" "$G"
check "n1-init Atlassian names" "atlassianUserInfo.*editJiraIssue" "$G"
check "n1-init jc-mcp names" "jcm_getCurrentUser.*jcm_editIssue" "$G"
check "n1-init YouTrack names" "get_current_user.*change_issue_assignee" "$G"
check "n1-init unknown scheme skips" "cannot infer operation names" "$G"

# jq patch from the skill: fills only null/empty keys, leaves everything else alone
FILTER=$(grep -o "'\.tracker\.operations\.getCurrentUser |= [^']*'" "$G" | head -1 | sed "s/^'//; s/'\$//")
if [ -z "$FILTER" ]; then
    fail "n1-init jq patch extractable"
else
    got=$(printf '%s' '{"tracker":{"type":"jira","other":1,"operations":{"assign":"","update":"keep"}}}' \
        | jq -c --arg g GCU --arg a ASG "$FILTER")
    want='{"tracker":{"type":"jira","other":1,"operations":{"assign":"ASG","update":"keep","getCurrentUser":"GCU"}}}'
    [ "$got" = "$want" ] && pass "jq patch fills empty/missing keys only" || fail "jq patch fills empty/missing keys only: $got"
    got=$(printf '%s' '{"tracker":{"operations":{"getCurrentUser":"x","assign":"update_issue"}}}' \
        | jq -c --arg g GCU --arg a ASG "$FILTER")
    [ "$got" = '{"tracker":{"operations":{"getCurrentUser":"x","assign":"update_issue"}}}' ] \
        && pass "jq patch leaves present values (even wrong ones) alone" || fail "jq patch leaves present values alone: $got"
fi

# ---- docs ----
if grep -q "silently skipped when those operations are absent" references/architecture.md; then
    fail "architecture.md no longer says silently skipped"
else
    pass "architecture.md no longer says silently skipped"
fi
check "architecture.md documents the warning" "n1_assign_gap_warn" references/architecture.md
check "architecture.md documents the backfill" "Operation Gap Check" references/architecture.md

exit "$FAIL"
