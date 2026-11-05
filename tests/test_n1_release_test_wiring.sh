#!/usr/bin/env bash
# tests/test_n1_release_test_wiring.sh -- N1-176: n1-release-test gate, scope warnings, status merge and text rules.
# Snippets are extracted from the step files and run in a sandbox.
# Run: bash tests/test_n1_release_test_wiring.sh
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
S=skills/n1-release-test
S1=$S/steps/01-gate-scope.md; S2=$S/steps/02-plan.md; S3=$S/steps/03-run.md; S4=$S/steps/04-publish-report.md
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect() { if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; FAIL=1; fi; }
check() { if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi; }
lacks() { if grep -rqE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi; }

snip() { awk -v h="$1" 'index($0, h) == 1 {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b' "$2"; }
mkdir -p "$T/home/.n1" "$T/n1"
printf 'N1_ROOT=%q\nsource %q\n' "$PWD" "$PWD/lib/config.sh" > "$T/home/.n1/preamble.sh"
sandbox() { (export HOME="$T/home" N1_HOME="$T/n1"; bash -c "$1" 2>/dev/null); }
cfg() { echo "$1" > "$T/n1/config.json"; }

# --- Gate. Bug: the skill runs and writes files when release.enabled is false or absent.
GATE=$(snip "## 1a." "$S1")
cfg '{"release":{"enabled":false},"tracker":{"prefix":"VEL"}}'
expect "gate refuses release.enabled=false" "n1-release-test requires release.enabled=true" "$(sandbox "$GATE")"
cfg '{"tracker":{"prefix":"VEL"}}'
expect "gate refuses an absent key" "n1-release-test requires release.enabled=true" "$(sandbox "$GATE")"
cfg '{"release":{"enabled":true},"tracker":{"prefix":"VEL"}}'
expect "gate passes release.enabled=true" "gate:ok" "$(sandbox "$GATE")"

# --- Label. Bug: an already released version, or a path-unsafe version, names the release directory.
G="$T/repo"; git init -q "$G"
gc() { git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
gc '[VEL-1] first'; git -C "$G" update-ref refs/tags/v1.0.0 HEAD; gc '[VEL-2] second'; gc 'chore: bump version'
SHA7=$(git -C "$G" rev-parse --short=7 HEAD)
LABEL=$(snip "## 1c." "$S1")
label_run() { (cd "$G" && sandbox "${LABEL//<VERSION, or empty>/$1}"); }
expect "new version labels the release" "PREV=v1.0.0 LABEL=1.1.0 FIX=yes" "$(label_run 1.1.0)"
expect "version equal to PREV: unreleased label, no fixVersion" "PREV=v1.0.0 LABEL=unreleased-$SHA7 FIX=no" "$(label_run 1.0.0)"
expect "empty version: unreleased label" "PREV=v1.0.0 LABEL=unreleased-$SHA7 FIX=no" "$(label_run '')"
expect "path-unsafe version: unreleased label" "PREV=v1.0.0 LABEL=unreleased-$SHA7 FIX=no" "$(label_run '../x')"

# --- Scope. Bug: a missed integrity warning lets the signal print GO over an incomplete scope.
echo '{"pending":[{"id":"VEL-2"},{"id":"VEL-9"},{"id":"x;touch PWNED"}]}' > "$T/n1/pending-releases.json"
SCOPE=$(snip "## 1e." "$S1")
SCOPE=${SCOPE//<LABEL>/1.1.0}; SCOPE=${SCOPE//<PREV, or empty>/v1.0.0}
SCOPE=${SCOPE//<1 when off the default branch, else 0>/1}; SCOPE=${SCOPE//<validated fixVersion keys, space-separated, or empty>/VEL-8}
OUT=$(cd "$G" && sandbox "$SCOPE")
expect "scope unions git, pending and fixVersion; drops invalid IDs" "ticket: VEL-2
ticket: VEL-8
ticket: VEL-9" "$(grep '^ticket:' <<<"$OUT")"
expect "unticketed commit warned" "1" "$(grep -c '^warning: unticketed commit .*chore: bump version' <<<"$OUT")"
expect "commit-less tickets warned" "warning: commit-less ticket VEL-8
warning: commit-less ticket VEL-9" "$(grep '^warning: commit-less' <<<"$OUT")"
expect "warning count includes off-default" "WARN=4" "$(grep '^WARN=' <<<"$OUT")"
expect "release diff written" "yes" "$([ -s "$T/n1/releases/1.1.0/release.diff" ] && echo yes)"
expect "pending file untouched" "3" "$(jq '.pending | length' "$T/n1/pending-releases.json")"

# --- Status merge. Bugs: a stale page value overrides an auto result; a missing result reads as PASS;
# free-text QA notes count as PASS; QA values for removed cases vanish silently.
D="$T/n1/releases/1.1.0"
cat > "$D/release-test-plan.md" <<'EOF'
| ID | Tickets | Risk | Class | Reason | Preconditions / test data | Steps and expected |
|---|---|---|---|---|---|---|
| RT-01 | VEL-1 | High | auto | api | none | 1) GET /x -> 200 |
| RT-02 | VEL-1 | Medium | auto | api | none | 1) GET /y -> 200 |
| RT-03 | VEL-2 | High | manual | visual | none | 1) look |
| RT-04 | VEL-2 | Low | assisted | judgement | none | 1) run |
| RT-05 | VEL-2 | Low | manual | visual | none | 1) look |
EOF
cat > "$D/release-test-results.md" <<'EOF'
| Case | Status | Check / evidence | Reason |
|---|---|---|---|
| RT-01 | PASS | GET /x -> 200 \| ok | - |
Dev build: verified
EOF
cat > "$D/page-body.md" <<'EOF'
| ID | Tickets | Risk | Class | Steps and expected | Result |
| --- | --- | --- | --- | --- | --- |
| RT-01 | VEL-1 | High | auto | 1) x | FAIL |
| RT-03 | VEL-2 | High | manual | 1) look | pass |
| RT-04 | VEL-2 | Low | assisted | 1) run | blocked by env |
| RT-05 | VEL-2 | Low | manual | 1) look |  |
| RT-99 | VEL-3 | Low | manual | 1) old | PASS |
EOF
MERGE=$(snip "## 4d." "$S4"); MERGE=${MERGE//<LABEL>/1.1.0}
OUT=$(sandbox "$MERGE")
expect "merge: auto from results, manual and assisted from the page" "RT-01	High	auto	PASS
RT-02	Medium	auto	UNVERIFIED
RT-03	High	manual	PASS
RT-04	Low	assisted	MANUAL
RT-05	Low	manual	MANUAL" "$(cat "$D/case-status.tsv")"
expect "merge: Results of removed cases are reported" "dropped: RT-99 = PASS" "$(grep '^dropped:' <<<"$OUT")"
printf 'plain text page\n' > "$D/page-body.md"
expect "merge: unparsable page is flagged" "page:unparsable" "$(sandbox "$MERGE" | grep '^page:')"
rm -f "$D/page-body.md"

# --- Signal. Bug: a bare "Dev build: verified" claim with no evidence removes the D4 condition.
SIG=$(snip "## 4f." "$S4"); SIG=${SIG//<LABEL>/1.1.0}; SIG=${SIG//<integrity warnings plus publish failures>/0}
printf 'RT-01\tLow\tauto\tPASS\n' > "$D/case-status.tsv"
expect "signal: build claim without evidence stays unverified" "GO with conditions
condition: dev build not verified as HEAD" "$(sandbox "$SIG")"
echo 'Dev build: verified (health reports abc1234)' > "$D/release-test-results.md"
expect "signal: build with evidence reaches GO" "GO" "$(sandbox "$SIG")"

# --- Text rules
check "scope step calls n1_release_prev_tag" 'n1_release_prev_tag' "$S1"
check "scope step calls n1_release_ticket_ids" 'n1_release_ticket_ids' "$S1"
check "publish step calls n1_release_page_results" 'n1_release_page_results' "$S4"
check "publish step calls n1_release_signal" 'n1_release_signal' "$S4"
check "run step dispatches the verifier by name" 'post-deploy-verifier' "$S3"
check "plan step keeps existing case IDs" 'never renumber' "$S2"
check "unparsable page is not overwritten" 'do not call .*updateArticle' "$S4"
check "report reserves the Dev observability section" '## Dev observability' "$S4"
check "next actions point to the question format rule" 'references/question-format\.md' "$S4"
check "FAIL next actions mark one recommendation" '^1 — make a change \(Recommended\): ' "$S4"
check "UNVERIFIED next actions mark one recommendation" '^1 — re-check \(Recommended\): ' "$S4"
expect "each next-action list marks exactly one recommendation" "2" "$(grep -cF '(Recommended)' "$S4")"
check "other next actions carry a works-when note" '^[23] — .*: works when ' "$S4"
# Bugs: Jira drops checkbox lines from the page; the skill must never file tickets or reset the release batch.
lacks "no checkbox list syntax" '^[[:space:]]*- \[ \]' "$S"
lacks "no write to pending-releases.json" '>[[:space:]]*"?\$N1_HOME/pending-releases' "$S"
if grep -rE 'operations\.create' "$S" | grep -qv 'operations\.createArticle'; then echo "FAIL: no ticket-creation op"; FAIL=1; else echo "PASS: no ticket-creation op"; fi
lacks "host-neutral: no host tool names" 'AskUserQuestion|ToolSearch|spawn_agent|Agent tool' "$S"

exit $FAIL
