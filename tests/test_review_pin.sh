#!/usr/bin/env bash
# N1-141: per-PR reviewed-head pin (n1_review_pin) and its wiring in n1-pr and reconcile § Check.
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/config.sh; source lib/step.sh
ROOT=$PWD
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") [ -z "${REPO_FAIL:-}" ] || exit 1; echo "${REPO-o/r}" ;;
  "pr view") case "$*" in *headRefName*) echo "${BRANCH-tb}" ;; *) echo "${HEADSHA:-}" ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" N1_HOME="$T/home"
unset HEADSHA REPO REPO_FAIL BRANCH N1_SESSION_ID CLAUDE_CODE_SESSION_ID N1_RUN_ID
git init -q "$T/repo"; cd "$T/repo"
tip() { echo "$1" > .git/refs/heads/tb; }   # local PR-branch tip (what N1 pushed)
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333
tip $A
PIN="$T/home/review-pins/o_r_7"

eq "get: no pin prints nothing" "" "$(n1_review_pin get 7)"
eq "get: repo lookup failure -> unavailable" "unavailable" "$(REPO_FAIL=1 n1_review_pin get 7)"
tip $B; eq "set: head != local tip -> unavailable" "pin:unavailable" "$(HEADSHA=$A n1_review_pin set 7)"
[ ! -e "$T/home/review-pins/o_r_7" ] && ok "set: foreign head writes no pin" || no "set: foreign head wrote a pin"
tip $A
eq "set: reports the pinned head" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 7)"
eq "set: file holds the head" "$A" "$(cat "$PIN" 2>/dev/null)"
eq "get: roundtrip" "$A" "$(n1_review_pin get 7)"
eq "set: invalid head -> unavailable" "pin:unavailable" "$(HEADSHA=abc n1_review_pin set 7)"
eq "set: invalid head keeps the old pin" "$A" "$(cat "$PIN")"
eq "set: empty head -> unavailable" "pin:unavailable" "$(HEADSHA= n1_review_pin set 7)"
eq "advance: from != pin -> kept" "pin:kept" "$(n1_review_pin advance 7 "$C" "$B")"
eq "advance: kept leaves the pin" "$A" "$(cat "$PIN")"
eq "advance: NOW != local tip (n1-ci pushed nothing, foreign push) -> kept" "pin:kept" "$(n1_review_pin advance 7 "$A" "$B")"
eq "advance: kept leaves the pin" "$A" "$(n1_review_pin get 7)"
tip $B
eq "advance: from == pin and NOW == local tip -> advanced" "pin:advanced 2222222" "$(n1_review_pin advance 7 "$A" "$B")"
echo "$C" > .git/refs/heads/other; eq "advance: PR branch missing locally, other branch at NOW -> kept" "pin:kept" "$(BRANCH=gone n1_review_pin advance 7 "$B" "$C")"; rm -f .git/refs/heads/other
eq "advance: pin moved to the new head" "$B" "$(cat "$PIN")"
eq "advance: invalid target -> unavailable" "pin:unavailable" "$(n1_review_pin advance 7 "$B" zz)"
eq "advance: invalid target keeps the pin" "$B" "$(cat "$PIN")"
eq "advance: no pin -> kept" "pin:kept" "$(n1_review_pin advance 8 "" "$B")"
[ ! -e "$T/home/review-pins/o_r_8" ] && ok "advance: no pin creates nothing" || no "advance: no pin created a file"
eq "set: non-digit PR rejected" "pin:unavailable" "$(HEADSHA=$A n1_review_pin set '7;x')"
eq "get: non-digit PR -> unavailable" "unavailable" "$(n1_review_pin get '../7')"
eq "set: repo lookup failure -> unavailable" "pin:unavailable" "$(REPO_FAIL=1 HEADSHA=$A n1_review_pin set 9)"
eq "set: unsafe repo name rejected" "pin:unavailable" "$(REPO='o/r x' HEADSHA=$A n1_review_pin set 9)"
eq "set: rejected inputs write nothing" "o_r_7" "$(ls "$T/home/review-pins")"
echo junk > "$PIN"
eq "get: corrupt pin prints nothing" "" "$(n1_review_pin get 7)"
eq "advance: corrupt pin is never advanced" "pin:kept" "$(n1_review_pin advance 7 junk "$B")"
tip $C; eq "set: overwrites a corrupt pin" "pin:set 3333333" "$(HEADSHA=$C n1_review_pin set 7)"
eq "no temp files left behind" "0" "$(find "$T/home/review-pins" -name '*.*' | wc -l | tr -d ' ')"
n1_review_pin bogus 7 >/dev/null; eq "unknown op fails" "1" "$?"

# N1-182: set refuses without review artifacts for the active run; --confirmed, SKIP record and
# review-cr.md pass; advance is never gated; no active-run ticket fails open.
P11="$T/home/review-pins/o_r_11"; R="$T/home/memory/T-1"; tip $A
printf '{"ticketId":"T-1","runId":"r","worktreePath":null,"branch":"tb"}\n' > "$T/home/active-run.json"
out=$(HEADSHA=$A n1_review_pin set 11 2>"$T/err"); rc=$?
eq "guard: no review artifacts -> refused" "pin:refused no-review-artifacts T-1 (run the review step; do not hand-write the pin)" "$out"
eq "guard: refusal returns 1" "1" "$rc"
[ -s "$T/err" ] && ok "guard: refusal explains on stderr" || no "guard: refusal explains on stderr"
[ ! -e "$P11" ] && ok "guard: refusal writes no pin" || no "guard: refusal wrote a pin"
eq "guard: --confirmed re-pin bypasses" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11 --confirmed)"
rm -f "$P11"; mkdir -p "$R"
printf 'Review skipped: DOC_CONFIG_ONLY diff\n' > "$R/review.md"
eq "guard: SKIP review.md allows the pin" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
rm -f "$P11" "$R/review.md"; : > "$R/review-cr.md"
eq "guard: empty review-cr.md still refused" "1" "$(HEADSHA=$A n1_review_pin set 11 >/dev/null 2>&1; echo $?)"
printf 'verdict: PASS\n' > "$R/review-cr.md"
printf '### Verdict: PASS\n' > "$R/review.md"
eq "guard: review-cr.md allows the pin" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
# SEC-1: the header verdict decides, not the reviewers' own verdict lines that follow it.
rm -f "$P11"; printf '### Verdict: FAIL\n### Verdict: PASS\n' > "$R/review.md"
eq "guard: FAIL header refused as review-failed" "pin:refused review-failed T-1 (the review verdict is not PASS; fix and re-review)" "$(HEADSHA=$A n1_review_pin set 11 2>/dev/null)"
rm -f "$R/review.md"
eq "guard: review-cr.md without review.md refused" "1" "$(HEADSHA=$A n1_review_pin set 11 >/dev/null 2>&1; echo $?)"
printf '### Verdict: PASS\n## Deferred Soft Findings\n- [CR-9] x\n' > "$R/review.md"
eq "guard: soft-pass PASS header allows the pin" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
# SEC-3: with step telemetry present, a review step event is required (any run file of the ticket).
rm -f "$P11"; mkdir -p "$R/telemetry/raw/steps"
printf '{"run_id":"r0","layer":"envelope"}\n{"run_id":"r0","layer":"step","step":"qa","step_number":8}\n' > "$R/telemetry/raw/steps/r0.jsonl"
printf '{"ticketId":"T-1","runId":"r","worktreePath":null,"branch":"tb"}\n' > "$T/home/active-run.json"
eq "guard: no review step event -> refused" "pin:refused no-review-artifacts T-1 (run the review step; do not hand-write the pin)" "$(HEADSHA=$A n1_review_pin set 11 2>/dev/null)"
printf '{"run_id":"r0","layer":"step","step":"review","step_number":9,"outcome":"success","metadata":{"head":"%s"}}\n' "$A" >> "$R/telemetry/raw/steps/r0.jsonl"
eq "guard: review event in an earlier run file (resume) allows the pin" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
# CR-1: a space in the N1 home path must not split the step-file list.
SP="$T/home with space"; mkdir -p "$SP/memory/T-1/telemetry/raw/steps" "$SP/review-pins"
cp "$R/review-cr.md" "$R/review.md" "$SP/memory/T-1/"; cp "$R/telemetry/raw/steps/r0.jsonl" "$SP/memory/T-1/telemetry/raw/steps/"
cp "$T/home/active-run.json" "$SP/"
eq "guard: space in N1 home with review event allows the pin" "pin:set 1111111" "$(N1_HOME="$SP" HEADSHA=$A n1_review_pin set 11)"
rm -f "$P11"; printf '{"ticketId":"T-1","runId":"none","worktreePath":null,"branch":"tb"}\n' > "$T/home/active-run.json"
rm -f "$R/telemetry/raw/steps/r0.jsonl"; printf '{"run_id":"r1","layer":"step","step":"qa"}\n' > "$R/telemetry/raw/steps/r1.jsonl"
eq "guard: runId none skips the event anchor" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
printf '{"ticketId":"T-1","runId":"r","worktreePath":null,"branch":"tb"}\n' > "$T/home/active-run.json"
rm -rf "$R/telemetry"
rm -f "$R/review-cr.md" "$R/review.md"; tip $B
eq "guard: advance is not gated" "pin:advanced 2222222" "$(n1_review_pin advance 11 "$A" "$B")"
tip $A; rm -f "$P11"
printf '{"ticketId":"","runId":""}\n' > "$T/home/active-run.json"
eq "guard: active run without ticketId fails open" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"
rm -f "$T/home/active-run.json" "$P11"
eq "guard: no active-run pointer fails open" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 11)"

# N1-184: the PR head must be the reviewed SHA or the end of the recorded post-review head chain.
R="$T/home/memory/T-1"; ST="$R/telemetry/raw/steps"; P11="$T/home/review-pins/o_r_11"
gc() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1" && git rev-parse HEAD; }
rv() {  # rv <run> [head]: append an ended review event to run file <run>
    local m=""; [ -z "${2:-}" ] || m=",\"metadata\":{\"head\":\"$2\"}"
    printf '{"run_id":"%s","layer":"step","step":"review","step_number":9,"outcome":"success"%s}\n' "$1" "$m" >> "$ST/$1.jsonl"
}
pin() { rm -f "$P11"; HEADSHA="$1" n1_review_pin set 11 2>/dev/null; }
hr() { N1_RUN_ID=r2 ID=T-1 n1_head_record "$1"; }
REF="pin:refused unreviewed-head T-1 (head is not the reviewed SHA or a recorded post-review head; re-run review)"
rm -rf "$R"; mkdir -p "$ST" "$R/telemetry/locks"; : > "$R/telemetry/locks/r2.json"
printf 'verdict: PASS\n' > "$R/review-cr.md"; printf '### Verdict: PASS\n' > "$R/review.md"
printf '{"ticketId":"T-1","runId":"r2","worktreePath":null,"branch":"tb"}\n' > "$T/home/active-run.json"
H1=$(gc reviewed); tip "$H1"
rv r2
eq "binding: review event without head -> refused" "$REF" "$(pin "$H1")"
rm -f "$P11"; out=$(HEADSHA=$H1 n1_review_pin set 11 2>"$T/err"); rc=$?
eq "binding: refusal returns 1" "1" "$rc"
grep -qF 'review head chain' "$T/err" && ok "binding: refusal explains on stderr" || no "binding: refusal explains on stderr"
rm -f "$ST"/*.jsonl; rv r1 "$H1"
printf '{"run_id":"r2","layer":"step","step":"qa","step_number":8,"outcome":"success"}\n' > "$ST/r2.jsonl"
H2=$(gc unreviewed); tip "$H2"
eq "binding: earlier run's review event and review.md do not authorize a later head" "$REF" "$(pin "$H2")"
rv r2 "$H1"
eq "binding: head != reviewed SHA -> refused" "$REF" "$(pin "$H2")"
hr "$H1"
eq "n1_head_record: metadata holds head and from" "{\"head\":\"$H2\",\"from\":\"$H1\"}" "$(tail -1 "$ST/r2.jsonl" | jq -c .metadata)"
eq "n1_head_record: event is an ended head step" "head 0 success" "$(tail -1 "$ST/r2.jsonl" | jq -r '"\(.step) \(.step_number) \(.outcome)"')"
eq "binding: recorded soft-fix head allowed" "pin:set ${H2:0:7}" "$(pin "$H2")"
H3=$(gc docs); tip "$H3"; hr "$H2"
eq "binding: recorded doc-commit head allowed" "pin:set ${H3:0:7}" "$(pin "$H3")"
H4=$(gc rebased); tip "$H4"; hr "$H3"
eq "binding: rebase from the last recorded head re-anchors" "pin:set ${H4:0:7}" "$(pin "$H4")"
H5=$(gc manual); H6=$(gc rebased-again); tip "$H6"; hr "$H5"
eq "binding: rebase from an unrecorded commit -> refused" "$REF" "$(pin "$H6")"
hr "$H6"
eq "binding: a broken chain stays broken" "$REF" "$(pin "$H6")"
eq "binding: --confirmed still bypasses" "pin:set ${H6:0:7}" "$(rm -f "$P11"; HEADSHA=$H6 n1_review_pin set 11 --confirmed)"
rv r2 "$H6"
eq "binding: a re-review re-anchors the chain" "pin:set ${H6:0:7}" "$(pin "$H6")"
n=$(wc -l < "$ST/r2.jsonl"); out=$( unset N1_RUN_ID; ID=T-1 n1_head_record "$H6" 2>/dev/null ); rc=$?
eq "n1_head_record: no bound run writes nothing" "$n" "$(wc -l < "$ST/r2.jsonl")"
eq "n1_head_record: no bound run fails visibly (N1-439)" "1 HEAD_RECORD_FAILED" "$rc ${out%% *}"
H8=$(gc soft-fix); tip "$H8"; hr "$H6"; hr "$H6"
eq "binding: repeating a head record is a no-op" "pin:set ${H8:0:7}" "$(pin "$H8")"
# N1-405 AC4: pre-push Codex fix commits recorded by the scope gate keep the chain intact through docs and rebase.
rv r2 "$H8"; H9=$(gc codex-fix-1); H10=$(gc codex-fix-2); tip "$H10"
eq "binding: unrecorded Codex fix head -> refused" "$REF" "$(pin "$H10")"
hr "$H8"
eq "binding: Codex fix commits recorded from the pre-Codex head allowed" "pin:set ${H10:0:7}" "$(pin "$H10")"
H11=$(gc docs-after-codex); hr "$H10"; H12=$(gc rebased-after-codex); tip "$H12"; hr "$H11"
eq "binding: docs and rebase after Codex fixes keep the chain" "pin:set ${H12:0:7}" "$(pin "$H12")"
rm -f "$ST"/*.jsonl; rv r1 "$H1"; rv r2 "$H2"
printf '{"run_id":"r2","layer":"step","step":"review","step_number":9}\n' >> "$ST/r2.jsonl"
tip "$H1"; eq "binding: older run's review head is refused" "$REF" "$(pin "$H1")"
tip "$H2"
eq "binding: newest review head wins; begin event ignored" "pin:set ${H2:0:7}" "$(pin "$H2")"
rm -f "$ST"/*.jsonl; printf '{"run_id":"r2","layer":"step","step":"review","step_number":9,"outcome":"success","metadata":{"head":""}}\n{"run_id":"r2","layer":"step","step":"head","step_number":0,"outcome":"success","metadata":{"head":"%s","from":""}}\n' "$H6" > "$ST/r2.jsonl"
eq "binding: empty review head and empty from -> refused" "$REF" "$(pin "$H6")"
n=$(wc -l < "$ST/r2.jsonl"); out=$(hr ""); rc=$?
eq "n1_head_record: malformed from writes nothing" "$n" "$(wc -l < "$ST/r2.jsonl")"
eq "n1_head_record: malformed from fails visibly (N1-439)" "1 HEAD_RECORD_FAILED" "$rc ${out%% *}"
rv r2 "$H6"; tip "$H6"; pin "$H6" >/dev/null
H7=$(gc ci-fix); tip "$H7"
eq "binding: advance is not gated by the chain" "pin:advanced ${H7:0:7}" "$(n1_review_pin advance 11 "$H6" "$H7")"
# N1-439: n1_review_reviewed_head is the pre-PR re-review diff base; n1_head_record derives ID from the active run.
eq "reviewed head: last ended review event with a head" "$H6" "$(n1_review_reviewed_head "$T/home")"
eq "reviewed head: no active run prints nothing" "" "$(N1_HOME="$T/none" n1_review_reviewed_head "$T/none")"
H14=$(gc derived-id); ( unset ID; N1_RUN_ID=r2 n1_head_record "$H7" ) >/dev/null
eq "n1_head_record: unset ID derives the ticket from the active run" "{\"head\":\"$H14\",\"from\":\"$H7\"}" "$(tail -1 "$ST/r2.jsonl" | jq -c .metadata)"
mv "$T/home/active-run.json" "$T/ar.bak"; out=$( unset ID N1_RUN_ID; n1_head_record "$H7" 2>/dev/null ); rc=$?; mv "$T/ar.bak" "$T/home/active-run.json"
eq "n1_head_record: no active run (standalone n1-pr) stays silent" "0:" "$rc:$out"
# N1-439 AC2: the pre-PR gate fence in pr.md writes fix.diff from the last reviewed head; a re-review re-anchors.
echo fix > lt.txt; git add lt.txt; H13=$(gc local-test-fix); tip "$H13"
eq "gate: unrecorded local-test fix commit -> rc 3" "3" "$(n1_review_artifacts_ok "$T/home" "$H13" >/dev/null; echo $?)"
blk() { awk -v p="$2" '/^```bash/{b="";f=1;next} f&&/^```/{f=0;if(index(b,p)){printf "%s",b;exit};next} f{b=b $0 "\n"}' "$1"; }
GB=$(blk "$ROOT/skills/n1-start/steps/pr.md" pre_pr_review_cycle | sed '/^source /d')
if [ -n "$GB" ]; then ok "gate: pr.md carries the pre-PR gate fence"; else no "gate: pr.md carries the pre-PR gate fence"; fi
echo stale > "$R/fix.diff"; ( n1_increment_counter() { :; }; ID=T-1; eval "$GB" ) >/dev/null
eq "gate: fix-changed-files lists the post-review commit" "lt.txt" "$(cat "$R/fix-changed-files" 2>/dev/null)"
if grep -qx '+fix' "$R/fix.diff"; then ok "gate: fix.diff runs from the last reviewed head"; else no "gate: fix.diff runs from the last reviewed head"; fi
E="$T/nohead"; mkdir -p "$E/memory/T-1/telemetry/raw/steps"; cp "$T/home/active-run.json" "$E/"
printf '{"run_id":"r2","layer":"step","step":"review","step_number":9,"outcome":"success"}\n' > "$E/memory/T-1/telemetry/raw/steps/r2.jsonl"
echo stale > "$E/memory/T-1/fix.diff"; ( n1_increment_counter() { :; }; ID=T-1; N1_HOME="$E"; eval "$GB" ) >/dev/null
eq "gate: unknown reviewed head empties fix.diff (full-scope re-review)" "0" "$(wc -c < "$E/memory/T-1/fix.diff" | tr -d ' ')"
rv r2 "$H13"
eq "gate: re-review at the moved HEAD re-anchors the chain" "0" "$(n1_review_artifacts_ok "$T/home" "$H13" >/dev/null; echo $?)"
rm -rf "$R" "$T/home/active-run.json" "$P11"

# Wiring (N1-405): step 3 pins the PR head and never runs Codex; the pre-push scope gate records the fix head.
cd - >/dev/null; S3=skills/n1-pr/steps/03-codex-review.md; CTR=skills/n1-pr/procedures/codex-triage.md
if grep -qF 'n1_review_pin set "${PR_URL##*/}"' "$S3"; then ok "n1-pr step 3 pins the PR head"; else no "n1-pr step 3 pins the PR head"; fi
if grep -qF 'codex-pr-review.sh' "$S3"; then no "n1-pr step 3 never runs the Codex runner"; else ok "n1-pr step 3 never runs the Codex runner"; fi
if grep -qF 'push:ok) n1_head_record "$START"' "$CTR"; then ok "Codex scope gate records the fix head"; else no "Codex scope gate records the fix head"; fi

# N1-182: only the user-confirmed n1-finish re-pins bypass the review guard.
for f in skills/n1-finish/references/repin.md skills/n1-finish/references/resolve-dirty.md; do
    if grep -qxF 'n1_review_pin set "$N" --confirmed' "$f"; then ok "$f re-pins with --confirmed"; else no "$f re-pins with --confirmed"; fi
done
if grep -rnF -- '--confirmed' skills/n1-pr skills/n1-start | grep -q n1_review_pin; then no "n1-pr/n1-start never bypass the review guard"; else ok "n1-pr/n1-start never bypass the review guard"; fi
if grep -qF 'pin:refused' "$S3"; then ok "n1-pr explains pin:refused"; else no "n1-pr explains pin:refused"; fi

# N1-184: both review ends record HEAD; every post-review recorder is wired after its commit.
RV=skills/n1-start/steps/review.md
eq "review.md: both review ends record HEAD" "2" "$(grep -cF 'n1_step_end "review" 9 "success" "{\"head\":\"$(git rev-parse HEAD)\"}"' "$RV")"
eq "review.md: no review end without HEAD" "2" "$(grep -oF 'n1_step_end "review" 9 "success"' "$RV" | wc -l | tr -d ' ')"
if grep -qxF 'n1_head_record "$(cat "$N1_HOME/memory/$ID/pre-fix-sha")"' skills/n1-start/steps/fix.md; then ok "fix.md records the soft-fix head"; else no "fix.md records the soft-fix head"; fi
P1=skills/n1-pr/steps/01-prepare.md
DW=$(grep -nF 'git rev-parse HEAD > "$N1_HOME/memory/$ID/docs-from-sha"' "$P1" | head -1 | cut -d: -f1)
TW=$(grep -nF '### Spawn tech-writer Phase 1 with:' "$P1" | head -1 | cut -d: -f1)
DR=$(grep -nxF 'n1_head_record "$(cat "$N1_HOME/memory/${ID:-}/docs-from-sha" 2>/dev/null)"' "$P1" | head -1 | cut -d: -f1)
if [ -n "$DW" ] && [ -n "$TW" ] && [ -n "$DR" ] && [ "$DW" -lt "$TW" ] && [ "$TW" -lt "$DR" ]; then ok "n1-pr records the doc-commit head around tech-writer"; else no "n1-pr records the doc-commit head around tech-writer"; fi
P2=skills/n1-pr/steps/02-push-create.md
PR0=$(grep -nxF 'PRE_REBASE=$(git rev-parse HEAD)' "$P2" | head -1 | cut -d: -f1)
RB=$(grep -nxF 'git rebase "origin/$DEFAULT_BRANCH" && { n1_head_record "$PRE_REBASE"; n1_review_reanchor "$PRE_REBASE"; }' "$P2" | head -1 | cut -d: -f1)
if [ -n "$PR0" ] && [ -n "$RB" ] && [ "$PR0" -lt "$RB" ]; then ok "n1-pr records the head only after a clean rebase"; else no "n1-pr records the head only after a clean rebase"; fi
if [ "$(grep -cE '^n1_codex_gate_check "\$ID" && git push' "$P2")" = 2 ] && grep -qF 'n1_codex_gate_check "$ID" ||' skills/n1-pr/procedures/codex-triage.md; then ok "every n1-pr push path and the Codex Fix Phase honour the blocked-gate marker"; else no "every n1-pr push path and the Codex Fix Phase honour the blocked-gate marker"; fi
if grep -qF 'unreviewed-head' "$S3"; then ok "n1-pr explains pin:refused unreviewed-head"; else no "n1-pr explains pin:refused unreviewed-head"; fi
if grep -qF '| 0 | `head` |' skills/n1-start/procedures/telemetry.md; then ok "telemetry.md documents the head event"; else no "telemetry.md documents the head event"; fi

# N1-439: the pre-PR gate runs before the pr step begins and before n1-pr; local testing points at it.
PM=skills/n1-start/steps/pr.md
G=$(grep -nF 'GATE_ID=$(n1_review_artifacts_ok "$N1_HOME" "$(git rev-parse HEAD)"); GATE_RC=$?' "$PM" | head -1 | cut -d: -f1)
SB=$(grep -nF 'n1_step_begin "pr" 12' "$PM" | head -1 | cut -d: -f1)
NP=$(grep -nF '`n1:n1-pr`' "$PM" | head -1 | cut -d: -f1)
if [ -n "$G" ] && [ -n "$SB" ] && [ -n "$NP" ] && [ "$G" -lt "$SB" ] && [ "$SB" -lt "$NP" ]; then ok "pr.md gate runs before the pr step and n1-pr"; else no "pr.md gate runs before the pr step and n1-pr"; fi
if grep -qF '`1` (no review step ran' "$PM" && grep -qF 'return to Step 7' "$PM"; then ok "pr.md routes rc 1 and rc 3 to Step 7"; else no "pr.md routes rc 1 and rc 3 to Step 7"; fi
if grep -qF 'pre-PR gate' skills/n1-start/procedures/local-testing-run.md; then ok "local-testing fix commits point at the pre-PR gate"; else no "local-testing fix commits point at the pre-PR gate"; fi

for f in "$P2" "$CTR"; do
    if grep -qF 'HEAD_RECORD_FAILED' "$f"; then ok "$f checks HEAD_RECORD_FAILED"; else no "$f checks HEAD_RECORD_FAILED"; fi
done

exit $FAIL
