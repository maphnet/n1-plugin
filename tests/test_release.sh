#!/usr/bin/env bash
# tests/test_release.sh -- N1-176: release scope helpers, Confluence Result parser and readiness signal.
# Run: bash tests/test_release.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source lib/release.sh

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }

# gh stub: `release list` prints $GH_TAG (empty by default).
mkdir "$T/bin"
cat > "$T/bin/gh" <<'EOG'
#!/usr/bin/env bash
[ "$1 $2" = "release list" ] && [ -n "${GH_TAG:-}" ] && printf '%s\n' "$GH_TAG"
exit 0
EOG
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_TAG=""

R="$T/repo"; git init -q "$R"
commit() { git -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
tag() { git -C "$R" update-ref "refs/tags/$1" HEAD; }
in_repo() { (cd "$R" && "$@"); }

# --- n1_release_prev_tag
# Bug: with no tags the helper must use the gh fallback, and a gh result equal to TAG must be dropped.
commit '[VEL-1] first'
GH_TAG=v0.9.0
eq "no local tags: no argument uses gh" "v0.9.0" "$(in_repo n1_release_prev_tag)"
eq "no local tags: gh result equal to --exclude is dropped" "" "$(in_repo n1_release_prev_tag --exclude v0.9.0)"
GH_TAG=
eq "no local tags and no gh result: empty" "" "$(in_repo n1_release_prev_tag)"

tag v1.0.0; commit '[VEL-2] second'; tag v1.1.0; commit '[VEL-3] third'
# Bug: a retry after tag-created-but-release-failed picks TAG as its own previous tag, so the range collapses.
eq "--exclude: retry path skips the existing target tag" "v1.0.0" "$(in_repo n1_release_prev_tag --exclude v1.1.0)"
# Bug (D6 trap): the next-older awk semantic prints nothing when TAG does not exist yet.
eq "--exclude: target tag not created yet gives the newest" "v1.1.0" "$(in_repo n1_release_prev_tag --exclude v2.0.0)"
eq "no argument: newest tag" "v1.1.0" "$(in_repo n1_release_prev_tag)"
eq "<tag>: next older" "v1.0.0" "$(in_repo n1_release_prev_tag v1.1.0)"
eq "<tag>: oldest has no previous tag" "" "$(in_repo n1_release_prev_tag v1.0.0)"
# Bug: <tag> mode must not consult gh (03b has no fallback), so a gh value here would be a wrong range.
GH_TAG=v0.9.0
eq "<tag>: absent tag is empty, gh not consulted" "" "$(in_repo n1_release_prev_tag v9.9.9)"
GH_TAG=
# Bug: tag names come from the remote; a hostile name must never reach the caller or run.
git -C "$R" update-ref 'refs/tags/v99$(touch${IFS}PWNED)' HEAD
eq "hostile newest tag is rejected" "" "$(in_repo n1_release_prev_tag)"
eq "hostile tag never executed" "0" "$(find "$R" -name PWNED | wc -l | tr -d ' ')"
git -C "$R" update-ref -d 'refs/tags/v99$(touch${IFS}PWNED)'

# --- n1_release_ticket_ids
export PREFIX=VEL
commit 'fix: handle VEL-1188 case'
commit '[VEL-4] Accept keys; drop key from VEL-1188 plan (#36)'
# Bug: IDs mentioned later in a subject, or untagged subjects, must not join the scope.
eq "range: leading tag only, older commits excluded" "VEL-3
VEL-4" "$(in_repo n1_release_ticket_ids v1.1.0 HEAD)"
eq "empty prev: whole history" "VEL-1
VEL-2
VEL-3
VEL-4" "$(in_repo n1_release_ticket_ids "" HEAD)"
# Bug: log.decorate=short prints "(tag: ..)" after the hash and breaks the leading-tag sed.
git -C "$R" config log.decorate short
eq "log.decorate=short still yields the ticket" "VEL-1
VEL-2" "$(in_repo n1_release_ticket_ids "" v1.1.0)"
out=$(in_repo n1_release_ticket_ids v9.9.9 HEAD); rc=$?
eq "bad range: empty output" "" "$out"
eq "bad range: rc 0" "0" "$rc"

# --- n1_release_page_results, pinned to literal jc-mcp 0.11.1 output
SAMPLE='# Release test svc 1.2.0

Scope: 2 tickets

| ID | Tickets | Risk | Class | Steps and expected | Result |
| --- | --- | --- | --- | --- | --- |
| RT-01 | VEL-1 | High | auto | 1) GET /a \| jq -> 200 | PASS |
| RT-02 | VEL-1 | Low | manual | 1) look |  |
| RT-03 | VEL-2 | Low | manual | 1) look | FAIL \| see note |

## Dev observability

not run (N1-179)'
# Bug: an escaped pipe in the steps cell shifts columns and QA results get lost or misattributed.
eq "0.11.1 sample: Results by ID, empty dropped, escaped pipe restored" "RT-01	PASS
RT-03	FAIL | see note" "$(n1_release_page_results <<<"$SAMPLE")"
# Bug: a human reordering columns must not swap the Result value with another cell.
eq "reordered columns are found by name" "RT-07	PASS" "$(n1_release_page_results <<<'| Result | ID |
| --- | --- |
| PASS | RT-07 |')"
# Bug: another table before or after the case table must not supply rows.
eq "other tables are ignored" "RT-08	FAIL" "$(n1_release_page_results <<<'| Name | Value |
| --- | --- |
| RT-09 | PASS |

| ID | Result |
| --- | --- |
| RT-08 | FAIL |

| ID | Result |
| --- | --- |
| RT-10 | PASS |')"
# Bug: the Tested at stamp must come back with the Result so a stale approval can be dropped.
eq "Tested at column is returned as a third field" "RT-01	PASS	abc-1" "$(n1_release_page_results <<<'| ID | Result | Tested at |
| --- | --- | --- |
| RT-01 | PASS | abc-1 |')"
# Bug: pre-0.11.1 bare lines must give rc 1, or the caller overwrites QA's results.
n1_release_page_results <<<$'RT-01\nPASS' >/dev/null; eq "bare lines: rc 1" "1" "$?"
out=$(n1_release_page_results <<<'| ID | Result |
| --- | --- |
| RT-01 |  |'); rc=$?
eq "parsable table, no Results: rc 0" "0" "$rc"
eq "parsable table, no Results: empty" "" "$out"

# --- n1_release_signal (D2 truth table)
sig() { local b="$1" w="$2"; shift 2; printf '%b\n' "$@" | n1_release_signal "$b" "$w"; }
# Bug: any of these turning into GO or NO-GO misreports release readiness.
eq "all PASS, build verified: GO" "GO" "$(sig verified 0 'High\tauto\tPASS' 'Low\tmanual\tpass')"
eq "High FAIL: NO-GO" "NO-GO" "$(sig verified 0 'High\tauto\tFAIL')"
eq "Critical FAIL beats conditions" "NO-GO" "$(sig verified 2 'Critical\tmanual\tFAIL' | head -1)"
eq "FAIL with an unknown tier fails closed" "NO-GO" "$(sig verified 0 '\tauto\tFAIL')"
eq "Low FAIL: conditions" "GO with conditions
condition: 1 Low/Medium FAIL case(s)" "$(sig verified 0 'Low\tauto\tFAIL')"
eq "UNVERIFIED: conditions" "GO with conditions
condition: 1 UNVERIFIED case(s)" "$(sig verified 0 'High\tauto\tUNVERIFIED')"
eq "MANUAL and PENDING: conditions" "GO with conditions
condition: 2 pending MANUAL or assisted case(s)" "$(sig verified 0 'Low\tmanual\tMANUAL' 'Low\tassisted\tPENDING')"
eq "warning: conditions" "GO with conditions
condition: 3 scope or publish warning(s)" "$(sig verified 3 'Low\tauto\tPASS')"
eq "build unverified caps at conditions (D4)" "GO with conditions
condition: dev build not verified as HEAD" "$(sig unverified 0 'Low\tauto\tPASS')"
eq "unknown status counts as UNVERIFIED" "GO with conditions
condition: 1 UNVERIFIED case(s)" "$(sig verified 0 'Low\tauto\tmaybe')"
eq "no cases is never GO" "GO with conditions
condition: no test cases" "$(n1_release_signal verified 0 </dev/null)"
eq "malformed warning count is a condition" "GO with conditions
condition: 1 scope or publish warning(s)" "$(sig verified x 'Low\tauto\tPASS')"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
