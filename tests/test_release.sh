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

# --- n1_release_blockers (N1-539)
blk() { local ids="$1"; shift; printf '%s\n' "$@" | n1_release_blockers "$ids"; }
IN_OPS7='{"id":"1","type":"Blocks","inwardIssue":"OPS-7"}'
OUT_VEL9='{"id":"2","type":"Blocks","outwardIssue":"VEL-9"}'
# Bug: inwardIssue on a Blocks link is "is blocked by"; outwardIssue is the reverse and must not warn.
eq "blockers: inwardIssue Blocks kept, outwardIssue ignored" $'OPS-7\tVEL-1' "$(blk VEL-1 "VEL-1"$'\t'"[$IN_OPS7,$OUT_VEL9]")"
# Bug: non-blocking link types must not produce a warning.
eq "blockers: non-Blocks link type ignored" "" "$(blk VEL-1 $'VEL-1\t[{"type":"Relates","inwardIssue":"OPS-8"}]')"
# Bug: a blocker shipped in the same release is not an unreleased blocker.
eq "blockers: blocker inside the release set dropped" "" "$(blk $'VEL-1\nVEL-2' $'VEL-1\t[{"type":"Blocks","inwardIssue":"VEL-2"}]')"
# Bug: a key blocking several release tickets must be read once, with every ticket listed.
eq "blockers: shared blocker grouped once, tickets sorted" $'OPS-7\tVEL-1,VEL-2' "$(blk $'VEL-1\nVEL-2' "VEL-2"$'\t'"[$IN_OPS7]" "VEL-1"$'\t'"[$IN_OPS7]")"
eq "blockers: distinct blockers sorted by key" $'OPS-7\tVEL-1\nOPS-8\tVEL-1' "$(blk VEL-1 $'VEL-1\t[{"type":"Blocks","inwardIssue":"OPS-8"},{"type":"Blocks","inwardIssue":"OPS-7"}]')"
# Bug (D7): tracker keys are untrusted; invalid keys, non-arrays and malformed JSON are dropped, never run, rc 0.
eq "blockers: invalid keys, non-array and malformed JSON dropped, rc 0" "rc=0" "$(cd "$T" && blk VEL-1 \
    $'vel-1\t[{"type":"Blocks","inwardIssue":"OPS-7"}]' \
    $'VEL-1\t[{"type":"Blocks","inwardIssue":"OPS-7$(touch${IFS}PWNED)"}]' \
    $'VEL-1\t{"type":"Blocks","inwardIssue":"OPS-9"}' \
    $'VEL-1\tnot json'; echo "rc=$?")"
eq "blockers: hostile blocker key never executed" "0" "$(find "$T" -name PWNED | wc -l | tr -d ' ')"
eq "blockers: no input, no output" "" "$(n1_release_blockers VEL-1 </dev/null)"

# --- n1_release_blocker_rows (N1-539)
rows() { local d="$1" p="$2"; shift 2; printf '%s\n' "$@" | n1_release_blocker_rows "$d" "$p"; }
# Bug (D4): done is a case-insensitive status-name match against tracker.statuses.done.
eq "rows: status equal to done-status in any case is done" $'OPS-7\tdone\tOPS\tDONE\tVEL-1\tFix it' "$(rows Done VEL $'OPS-7\tDONE\tVEL-1\tFix it')"
eq "rows: padded status still matches" $'OPS-7\tdone\tOPS\tDone\tVEL-1\tx' "$(rows Done VEL $'OPS-7\t Done \tVEL-1\tx')"
eq "rows: other status is not done" $'OPS-7\tnot done\tOPS\tIn Progress\tVEL-1\tFix it' "$(rows Done VEL $'OPS-7\tIn Progress\tVEL-1\tFix it')"
# Bug: an unset tracker.statuses.done must fail toward warning, never mark every blocker done.
eq "rows: empty done-status is not done" $'OPS-7\tnot done\tOPS\tDone\tVEL-1\tx' "$(rows '' VEL $'OPS-7\tDone\tVEL-1\tx')"
# Bug: a failed per-blocker read (empty status and title) must still warn.
eq "rows: failed read is not done, owner from prefix" $'OPS-7\tnot done\tOPS\t\tVEL-1\t' "$(rows Done VEL $'OPS-7\t\tVEL-1\t')"
# Bug (D1): the service tag in "<service> | <title>" names the owning service, ahead of the key prefix.
eq "rows: owner from title service tag" $'VEL-9\tnot done\tbilling-api\tTo Do\tVEL-1\tbilling-api | Add refunds' "$(rows Done VEL $'VEL-9\tTo Do\tVEL-1\tbilling-api | Add refunds')"
eq "rows: service tag beats foreign prefix, trailing spaces stripped" $'OPS-7\tnot done\tbilling-api\tTo Do\tVEL-1\tbilling-api  | x' "$(rows Done VEL $'OPS-7\tTo Do\tVEL-1\tbilling-api  | x')"
eq "rows: empty tag falls back to foreign prefix" $'OPS-7\tnot done\tOPS\tTo Do\tVEL-1\t | x' "$(rows Done VEL $'OPS-7\tTo Do\tVEL-1\t | x')"
# Bug (D1): a same-prefix key with no tag has no known owner; it must say unknown.
eq "rows: same prefix and no tag is unknown" $'VEL-9\tnot done\tunknown\tTo Do\tVEL-1\tPlain title' "$(rows Done VEL $'VEL-9\tTo Do\tVEL-1\tPlain title')"
# Bug: the prefix default must follow n1_release_ticket_ids (PREFIX env).
eq "rows: prefix defaults to PREFIX env" $'VEL-9\tnot done\tunknown\tTo Do\tVEL-1\tx' "$(printf '%s\n' $'VEL-9\tTo Do\tVEL-1\tx' | PREFIX=VEL n1_release_blocker_rows Done)"
# Bug: a tab inside a title would shift columns; extra fields are joined into the title.
eq "rows: tab inside title collapsed" $'OPS-7\tnot done\tOPS\tTo Do\tVEL-1\tpart one part two' "$(rows Done VEL $'OPS-7\tTo Do\tVEL-1\tpart one\tpart two')"
# Bug (D7): a row whose key fails the key pattern is dropped.
eq "rows: invalid key rows dropped" "" "$(rows Done VEL $'ops-7\tTo Do\tVEL-1\tx' $'OPS-7;rm\tTo Do\tVEL-1\tx')"

# --- n1_release_tag_date and n1_release_obs_window (N1-179)
R2="$T/repo2"; git init -q "$R2"
GIT_COMMITTER_DATE='2026-01-01T10:00:00+02:00' git -C "$R2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
GIT_COMMITTER_DATE='2026-02-01T10:00:00+02:00' git -C "$R2" -c user.name=t -c user.email=t@t tag -a v2.0.0 -m rel
git -C "$R2" update-ref refs/tags/v2.0.1 HEAD
in_r2() { (cd "$R2" && "$@"); }
# Bug: the scan window must start when the release was tagged, not when its last commit was made.
eq "tag date: annotated tag gives the tagger date" "2026-02-01T10:00:00+02:00" "$(in_r2 n1_release_tag_date v2.0.0)"
eq "tag date: lightweight tag gives the commit date" "2026-01-01T10:00:00+02:00" "$(in_r2 n1_release_tag_date v2.0.1)"
# Bug: an absent tag or a hostile name must give no date, so Step 3b skips instead of scanning from epoch 0 or running it.
eq "tag date: absent tag is empty" "" "$(in_r2 n1_release_tag_date v9.9.9)"
eq "tag date: non-semver name is empty" "" "$(in_r2 n1_release_tag_date 'v1$(id)')"
NOW=$(date +%s)
GIT_COMMITTER_DATE="$((NOW - 18600)) +0000" git -C "$R2" -c user.name=t -c user.email=t@t tag -a v3.0.0 -m rel
GIT_COMMITTER_DATE="$((NOW - 40 * 86400)) +0000" git -C "$R2" -c user.name=t -c user.email=t@t tag -a v3.1.0 -m rel
# Bug: a window rounded down misses the first hours after the tag; an uncapped window queries beyond Loki retention.
eq "window: hours rounded up, baseline doubled" "6 full 12" "$(in_r2 n1_release_obs_window v3.0.0)"
eq "window: capped at the default 720 h and flagged" "720 capped 720" "$(in_r2 n1_release_obs_window v3.1.0)"
eq "window: baseline respects N1_OBS_MAX_HOURS" "6 full 10" "$(N1_OBS_MAX_HOURS=10 in_r2 n1_release_obs_window v3.0.0)"
eq "window: absent tag is empty" "" "$(in_r2 n1_release_obs_window v9.9.9)"
# --- n1_release_obs_providers (N1-179)
cat > "$T/obs.json" <<'XEOF'
{"observability":{"default":"prod","providers":{
 "loki":{"env":"prod","mcp":"prod-loki","operations":{"query":"loki_query"},"instructions":"x"},
 "loki-dev":{"env":"dev","mcp":"publius-dev-loki-mcp","operations":{"query":"loki_query"},"instructions":"x"},
 "sentry-dev":{"env":"dev","mcp":"publius-sentry","operations":{"searchIssues":"search_issues","getIssue":"get_issue"},"instructions":"x"},
 "langfuse-dev":{"env":"dev","mcp":"publius-dev-langfuse-mcp","operations":{"findExceptions":"find_exceptions"},"instructions":"x"},
 "grafana-dev":{"env":"dev","mcp":"grafana","operations":{"dashboards":"list"},"instructions":"x"},
 "bad;name":{"env":"dev","mcp":"m","operations":{"query":"q"},"instructions":"x"},
 "global":{"mcp":"g","operations":{"query":"q"},"instructions":"x"}}}}
XEOF
# Bug (AC1): pilots set default prod; only env dev providers may be scanned, kind keyed on the operation,
# providers without a scan operation and names that are unsafe in a tool name are dropped.
eq "obs providers: dev only, kind from the operation" "loki-dev	publius-dev-loki-mcp	loki	loki_query
sentry-dev	publius-sentry	sentry	search_issues
langfuse-dev	publius-dev-langfuse-mcp	langfuse	find_exceptions" "$(n1_release_obs_providers "$T/obs.json")"
echo '{"observability":{"default":"prod","providers":{}}}' > "$T/obs-none.json"
# Bug (AC1): no dev provider must read as empty so Step 3b prints one skip line.
eq "obs providers: none configured is empty" "" "$(n1_release_obs_providers "$T/obs-none.json")"
# --- n1_release_obs_group (N1-179)
CUT='2026-02-01T10:00:00+02:00'
ROWS=$(printf '%s\t%s\t%s\t%s\n' \
  2026-02-01T07:59:59Z 2026-02-01T07:59:59Z 1 'Timeout for order 123 at 2026-02-01T07:59:59Z' \
  2026-02-03T00:00:00Z 2026-02-03T00:00:00Z 2 'Timeout for order 4567 at 2026-02-03T00:00:00Z' \
  1770336000 1770336000 1 'DB error id 550e8400-e29b-41d4-a716-446655440000 hash deadbeef01' \
  1770336000123 1770339600123 3 'DB error id 123e4567-e89b-12d3-a456-426614174000 hash cafebabe99' \
  bad 2026-02-03T00:00:00Z 1 'dropped row' \
  2026-02-03T00:00:00Z 2026-02-03T00:00:00Z x 'dropped row')
# Bug: IDs, hashes, numbers and timestamps split one error into many groups; a group first seen before the tag
# (cutoff 08:00Z) is labelled new; epoch ms is misread; groups are not newest-first.
eq "obs group: signatures merge, newest first, labels by cutoff" "db error id {id} hash {id}	4	2026-02-06T00:00:00Z	2026-02-06T01:00:00Z	new since release	DB error id 550e8400-e29b-41d4-a716-446655440000 hash deadbeef01
timeout for order {n} at {ts}	3	2026-02-01T07:59:59Z	2026-02-03T00:00:00Z	pre-existing	Timeout for order 123 at 2026-02-01T07:59:59Z" "$(n1_release_obs_group "$CUT" <<<"$ROWS" 2>/dev/null)"
# Bug: rows with a bad timestamp or count vanish silently, so the report understates what was seen.
eq "obs group: bad rows are counted on stderr" "dropped: 2" "$(n1_release_obs_group "$CUT" <<<"$ROWS" 2>&1 >/dev/null)"
# Bug: an offset timestamp equal to the tag time must count as new (>= cutoff), in UTC.
eq "obs group: offset normalized, cutoff inclusive" "boundary	1	2026-02-01T08:00:00Z	2026-02-01T08:00:00Z	new since release	boundary" \
  "$(printf '%s\t%s\t%s\t%s\n' 2026-02-01T10:00:00+02:00 2026-02-01T10:00:00+02:00 1 boundary | n1_release_obs_group "$CUT")"
# Bug: secrets in log lines reach Confluence, or table/shell metacharacters break the one-line cell.
eq "obs group: sample redacted and stripped" "Auth failed {redacted} {redacted} key {redacted} a b c d e f g" \
  "$(printf '%s\t%s\t%s\t%s\n' 2026-02-02T00:00:00Z 2026-02-02T00:00:00Z 1 \
     'Auth failed Authorization: Bearer abc.def password=hunter2 key AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA a|b`c$d<e>f\g' \
     | n1_release_obs_group "$CUT" | cut -f6)"
# Bug: a long log line bloats the Confluence page body without bound.
eq "obs group: signature 120 and sample 160 chars max" "120 160" \
  "$(printf '%s\t%s\t%s\t%s\n' 2026-02-02T00:00:00Z 2026-02-02T00:00:00Z 1 "$(printf 'word %.0s' {1..40})" \
     | n1_release_obs_group "$CUT" | awk -F'\t' '{print length($1), length($6)}')"
# Bug: an unparsable cutoff labels every group against epoch 0 or -1, so all of them read as new.
eq "obs group: bad cutoff gives no output" "" "$(n1_release_obs_group 'not-a-date' <<<"$ROWS" 2>/dev/null)"

echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
