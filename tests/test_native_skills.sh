#!/usr/bin/env bash
# Native skill tests: no Superpowers dependency in manifests, skill size budgets.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

# 1. No Superpowers in any manifest
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json; do
    if grep -qi 'superpowers' "$f" 2>/dev/null; then
        echo "FAIL: $f still references superpowers"; FAIL=1
    fi
done
[ $FAIL -eq 0 ] && echo "PASS: no superpowers in manifests"

# 2. Skill size budgets (in bytes)
check_size() { # <path-or-dir> <max-bytes> <label>
    local size
    if [ -d "$1" ]; then
        size=$(find "$1" -name '*.md' -exec cat {} + | wc -c)
    else
        size=$(wc -c < "$1")
    fi
    if [ "$size" -le "$2" ]; then
        echo "PASS: $3 is ${size}B (<= ${2}B)"
    else
        echo "FAIL: $3 is ${size}B (budget ${2}B)"; FAIL=1
    fi
}
check_size "skills/n1-brainstorm" 5120 "n1-brainstorm"
check_size "skills/n1-plan" 4096 "n1-plan"
check_size "skills/n1-implement" 8192 "n1-implement"

# 3. Codex review `codex exec` dispatch must never block on inherited stdin (NP-224)
REVIEW_RUNNER=scripts/codex-pr-review.sh
CODEX_LINE=$(grep -n 'codex exec' "$REVIEW_RUNNER" | head -1)
if echo "$CODEX_LINE" | grep -q 'timeout '; then
    echo "PASS: 03-codex-review codex exec is timeout-wrapped"
else
    echo "FAIL: 03-codex-review codex exec is missing a timeout wrapper"; FAIL=1
fi
if grep -A4 'codex exec' "$REVIEW_RUNNER" | grep -q '</dev/null'; then
    echo "PASS: 03-codex-review codex exec redirects stdin from /dev/null"
else
    echo "FAIL: 03-codex-review codex exec is missing </dev/null"; FAIL=1
fi

if grep -qE 'TIER=|tier.*complex|n1_host' skills/n1-pr/steps/03-codex-review.md skills/n1-pr/procedures/codex-triage.md 2>/dev/null; then
    echo "FAIL: 03-codex-review still gates on tier or host"; FAIL=1
else
    echo "PASS: 03-codex-review runs on every PR (no tier/host gate)"
fi

# 4. N1-70: the PR report/CHECKPOINT lives at the end of step 3, not step 2,
#    so the orchestrator never stops before the Codex review.
P2=skills/n1-pr/steps/02-push-create.md
P3=skills/n1-pr/steps/03-codex-review.md
TRI=skills/n1-pr/procedures/codex-triage.md
TRW=skills/n1-pr/procedures/codex-triage-worker.md
P1=skills/n1-pr/steps/01-prepare.md
if grep -q 'CHECKPOINT:' "$P2"; then
    echo "FAIL: 02-push-create still prints a CHECKPOINT"; FAIL=1
else
    echo "PASS: 02-push-create prints no CHECKPOINT"
fi
if grep -q '03-codex-review.md' <<<"$(grep -v '^[[:space:]]*$' "$P2" | tail -1)"; then
    echo "PASS: 02-push-create ends with continuation to step 3"
else
    echo "FAIL: 02-push-create does not end with continuation to step 3"; FAIL=1
fi
LAST_CP=$(grep -n 'CHECKPOINT: Ready for Tech Lead review.' "$P3" | tail -1 | cut -d: -f1)
if [ -n "$LAST_CP" ] && grep -qF 'procedures/codex-triage.md' "$P1" && grep -q '^### Triage File' "$TRI" 2>/dev/null \
   && grep -q '01-prepare.md' <<<"$(grep -v '^[[:space:]]*$' "$TRI" 2>/dev/null | tail -1)"; then
    echo "PASS: 03-codex-review ends with the PR report CHECKPOINT; pre-push triage returns to step 1"
else
    echo "FAIL: 03-codex-review CHECKPOINT/pre-push triage return path broken"; FAIL=1
fi
if grep -qiE 'stop here|skip this step entirely' "$P3" "$TRI" "$TRW" 2>/dev/null; then
    echo "FAIL: 03-codex-review or codex-triage has an early exit that bypasses the Report"; FAIL=1
else
    echo "PASS: 03-codex-review and codex-triage have no early exit before the Report"
fi
if grep -qF 'n1_record_decision codex-review' lib/codex-review.sh && grep -qF 'step-not-run' hooks/pr-review-observe.sh; then
    echo "PASS: 03-codex-review records skipped codex-review decisions"
else
    echo "FAIL: 03-codex-review does not record skipped codex-review decisions"; FAIL=1
fi

# 4b. N1-127/N1-405: triage text is read on demand from step 1; 03 keeps only pin, comment, notice and report
if [ -f "$TRI" ] && grep -qF 'procedures/codex-triage.md' "$P1"; then
    echo "PASS: 01-prepare points to the on-demand triage procedure"
else
    echo "FAIL: 01-prepare triage procedure pointer or file missing"; FAIL=1
fi
if grep -qE '^### (Severity Parsing|Validation|Fix Cycle|Reconcile PR Body|Triage Reply)' "$P3"; then
    echo "FAIL: 03-codex-review still inlines triage sections"; FAIL=1
else
    echo "PASS: 03-codex-review keeps triage sections in the procedure"
fi
P3_BYTES=$(wc -c < "$P3")
if [ "$P3_BYTES" -le 8000 ]; then
    echo "PASS: 03-codex-review is $P3_BYTES B (<= 8000)"
else
    echo "FAIL: 03-codex-review is $P3_BYTES B (> 8000)"; FAIL=1
fi

# 5. N1-70: dispatch budget/effort/prompt, outcome telemetry, and codex+post in one bash fence
for pat in 'N1_CROSS_HOST_REVIEW_TIMEOUT:-900' 'codex exec -c model_reasoning_effort=medium' 'do not run tests' 'n1_review_record'; do
    if grep -qF "$pat" "$REVIEW_RUNNER"; then
        echo "PASS: 03-codex-review has '$pat'"
    else
        echo "FAIL: 03-codex-review missing '$pat'"; FAIL=1
    fi
done
if ! grep -qE 'gh pr comment|gh pr ' "$REVIEW_RUNNER"; then
    echo "PASS: codex runner never calls gh (pre-push review, N1-405)"
else
    echo "FAIL: codex runner calls gh"; FAIL=1
fi

# 6. N1-94: Codex findings are validated by a read-only reviewer before developer fixes
first_line() { grep -n -m1 -E -- "$1" "$TRW" 2>/dev/null | cut -d: -f1; }
SEV=$(first_line '^### Severity Parsing'); VAL=$(first_line '^### Validation')
FIX=$(first_line '^### Fix Cycle'); TR=$(first_line '^### Triage Reply')
CRV=$(first_line 'n1_resolve_agent code-reviewer review')
if [ -n "$SEV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$SEV" -lt "$VAL" ] && [ "$VAL" -lt "$FIX" ]; then
    echo "PASS: codex-triage has Validation between Severity Parsing and Fix Cycle"
else
    echo "FAIL: codex-triage Validation section missing or misplaced"; FAIL=1
fi
if [ -n "$CRV" ] && [ -n "$VAL" ] && [ -n "$FIX" ] && [ "$CRV" -gt "$VAL" ] && [ "$CRV" -lt "$FIX" ]; then
    echo "PASS: codex-triage Validation dispatches code-reviewer"
else
    echo "FAIL: codex-triage Validation does not resolve code-reviewer"; FAIL=1
fi
for pat in 'Critical, High, or Medium' 'CONFIRMED | INVALID' '<CONFIRMED_FINDINGS>' 'git diff --no-color --no-ext-diff "$BASE...HEAD"'; do
    if grep -qF -- "$pat" "$TRW" 2>/dev/null; then
        echo "PASS: codex-triage has '$pat'"
    else
        echo "FAIL: codex-triage missing '$pat'"; FAIL=1
    fi
done
for pat in 'triage:posted' 'triage:none'; do
    if grep -qF -- "$pat" "$P3"; then
        echo "PASS: 03-codex-review gate has '$pat'"
    else
        echo "FAIL: 03-codex-review gate missing '$pat'"; FAIL=1
    fi
done
if grep -qF 'HIGH_PLUS' "$P3" "$TRI" "$TRW" 2>/dev/null; then
    echo "FAIL: codex triage developer still receives unvalidated High+ findings"; FAIL=1
else
    echo "PASS: codex triage developer receives only confirmed findings"
fi
if grep -qiE 'ask the user|wait for (the )?user' "$P3" "$TRI" "$TRW" 2>/dev/null; then
    echo "FAIL: codex triage prompts the user"; FAIL=1
else
    echo "PASS: codex triage never prompts the user"
fi
if [ -n "$TR" ] && sed -n "${TR},\$p" "$TRW" | grep -qF 'Dismissed by validator'; then
    echo "PASS: codex-triage Triage Reply lists validator dismissals"
else
    echo "FAIL: codex-triage Triage Reply lacks validator dismissals"; FAIL=1
fi

# 7. N1-94 SEC-1: untrusted triage text reaches the PR only through a file
if grep -qF -- '--body-file "$TRIAGE_FILE"' "$P3" 2>/dev/null && ! grep -qE 'TRIAGE_BODY=|printf .*\$TRIAGE_BODY' "$P3" "$TRI" "$TRW" 2>/dev/null; then
    echo "PASS: codex-triage posts triage via --body-file, never via shell variable"
else
    echo "FAIL: codex-triage triage reply splices text into shell"; FAIL=1
fi

# 8. N1-94 SEC-2 / CR-3: developer never pushes; orchestrator path gate; validator scope pins
if grep -qF 'Do NOT push' "$TRW" 2>/dev/null && grep -qF 'push:blocked' "$TRI" && grep -qF 'codex-push-gate.sh' "$TRI"; then
    echo "PASS: codex-triage gates the push on allowed paths"
else
    echo "FAIL: codex-triage push gate missing"; FAIL=1
fi
if grep -qF 'codex-blocked-fix.patch' "$TRI" 2>/dev/null && grep -qF 'needs out-of-scope file' "$TRW" && grep -qF 'reset=<sha>' "$TRW" && grep -qF 'kept=<sha>' "$TRW"; then
    echo "PASS: codex-triage passes the blocked-fix patch path and explains reset/kept and out-of-scope files"
else
    echo "FAIL: codex-triage lacks the blocked-fix patch path, reset/kept wording or out-of-scope dismissal"; FAIL=1
fi
for pat in 'Scope override' 'do not run git' 'UNVERIFIED' 'authoritative'; do
    if grep -qF -- "$pat" "$TRW" 2>/dev/null; then
        echo "PASS: codex-triage validator has '$pat'"
    else
        echo "FAIL: codex-triage validator missing '$pat'"; FAIL=1
    fi
done

# 9. N1-123 D1: the N1-116 soft-findings policy does not apply to Codex triage
for f in "$TRW" references/architecture.md; do
    if grep -qF 'does not apply to Codex triage (N1-123)' "$f"; then
        echo "PASS: $f records the N1-123 Codex triage decision"
    else
        echo "FAIL: $f missing the N1-123 Codex triage decision"; FAIL=1
    fi
done

# 10. N1-123 SEC-4: disclose soft-pass fixes as not cross-reviewed when Codex did not run
for pat in '### Soft-Fix Notice' '^## Fix Cycle [0-9]+ \(soft\)' 'not cross-reviewed' '--body-file "$SOFTFIX_FILE"' 'softfix:comment-failed' 'softfix:reviewed' 'softfix:no-id' 'softfix:bad-pr-url' 'softfix:unreadable' 'softfix:already-posted' 'gh pr view "$PR_URL" --json comments' 'gh pr comment "$PR_URL"' "ID='<the ticket ID>'" 'only the word after codex_review_outcome='; do
    if grep -qF -- "$pat" "$P3"; then
        echo "PASS: 03-codex-review soft-fix notice has '$pat'"
    else
        echo "FAIL: 03-codex-review soft-fix notice missing '$pat'"; FAIL=1
    fi
done
SF=$(grep -n '^### Soft-Fix Notice' "$P3" | head -1 | cut -d: -f1)
TG=$(grep -n '^## Step 10: Report' "$P3" | head -1 | cut -d: -f1)
if [ -n "$SF" ] && [ -n "$TG" ] && [ "$SF" -lt "$TG" ]; then
    echo "PASS: 03-codex-review Soft-Fix Notice precedes the Report"
else
    echo "FAIL: 03-codex-review Soft-Fix Notice must precede the Report"; FAIL=1
fi
if grep -qF '## Fix Cycle <N> (soft)' skills/n1-start/steps/fix.md && grep -qF -- '^## Fix Cycle [0-9]+ \(soft\)' "$P3"; then
    echo "PASS: soft Fix Cycle heading matches between fix.md and the notice grep"
else
    echo "FAIL: soft Fix Cycle heading drifted between fix.md and 03-codex-review.md"; FAIL=1
fi
if grep -qF 'Soft-fix disclosure (SEC-4, N1-123)' references/architecture.md; then
    echo "PASS: architecture.md documents the soft-fix disclosure and residual gap"
else
    echo "FAIL: architecture.md missing the soft-fix disclosure"; FAIL=1
fi
# N1-132: run the Soft-Fix Notice fence; gh is stubbed to prove it is never reached
SFT=$(mktemp -d)
mkdir -p "$SFT/home/.n1" "$SFT/bin" "$SFT/n1/memory/N1-1"
: > "$SFT/home/.n1/preamble.sh"
printf '#!/bin/sh\ntouch "%s/gh-called"\n' "$SFT" > "$SFT/bin/gh"; chmod +x "$SFT/bin/gh"
awk '/^### Soft-Fix Notice/{f=1} f&&/^```bash/{b=1;next} b&&/^```/{exit} b' "$P3" > "$SFT/fence.sh"
sf_run() { # $1=ID $2=OUTCOME
    sed -e "s|^ID=.*|ID='$1'|" -e "s|^OUTCOME=.*|OUTCOME='$2'|" "$SFT/fence.sh" |
        HOME="$SFT/home" N1_HOME="$SFT/n1" PATH="$SFT/bin:$PATH" bash 2>/dev/null
}
for c in "no-id|<the ticket ID>|skipped" "no-id|../x|skipped" "none|N1-1|skipped" "reviewed|N1-1|ran"; do
    IFS='|' read -r want id oc <<< "$c"
    if [ "$(sf_run "$id" "$oc")" = "softfix:$want" ]; then
        echo "PASS: soft-fix fence ID='$id' OUTCOME=$oc -> softfix:$want"
    else
        echo "FAIL: soft-fix fence ID='$id' OUTCOME=$oc did not print softfix:$want"; FAIL=1
    fi
done
if [ -e "$SFT/gh-called" ]; then
    echo "FAIL: soft-fix fence reached gh on a no-network path"; FAIL=1
else
    echo "PASS: soft-fix fence never reaches gh on no-id/none/reviewed paths"
fi
rm -rf "$SFT"

if grep -q 'qualityEscalations' skills/n1-pr/steps/03-codex-review.md && grep -q 'auto-accept' skills/n1-pr/steps/03-codex-review.md && grep -q 'never end with an offer or question to fix Codex findings' skills/n1-pr/steps/03-codex-review.md && grep -q 'never close Gate 3 with an offer or question to fix Codex findings' skills/n1-start/procedures/output-gates.md; then
    echo "PASS: 03-codex-review fixes all findings under auto-accept and never offers"
else
    echo "FAIL: 03-codex-review missing qualityEscalations auto-accept / no-offer rule"; FAIL=1
fi

# 9. N1-127: tech-writer writes the PR body to a file; 02 creates the PR from it
P1=skills/n1-pr/steps/01-prepare.md
TWR=agents/tech-writer.md
if grep -qF 'PR_BODY_FILE=$(mktemp "$N1_HOME/scratch/pr-body-' "$P1" && grep -qF 'body_file:' "$P1"; then
    echo "PASS: 01-prepare creates the PR body file and passes body_file"
else
    echo "FAIL: 01-prepare does not create/pass the PR body file"; FAIL=1
fi
if grep -qF '`body_file`' "$TWR" && grep -qF 'pr body written: <body_file>' "$TWR"; then
    echo "PASS: tech-writer writes the PR body to body_file"
else
    echo "FAIL: tech-writer has no body_file output"; FAIL=1
fi
if grep -q '^PR_BODY_FILE=' "$P2" && grep -qF -- '--body-file "$PR_BODY_FILE"' "$P2"; then
    echo "PASS: 02-push-create defines and uses PR_BODY_FILE"
else
    echo "FAIL: 02-push-create PR_BODY_FILE undefined or unused"; FAIL=1
fi
if grep -qF '[ -s "$PR_BODY_FILE" ] ||' "$P2"; then
    echo "PASS: 02-push-create refuses an empty PR body"
else
    echo "FAIL: 02-push-create does not guard an empty PR body"; FAIL=1
fi
if grep -rhE 'gh pr create' skills/n1-pr | grep -vE -- '--body-file' | grep -q .; then
    echo "FAIL: a gh pr create line in skills/n1-pr does not use --body-file"; FAIL=1
elif grep -rhE 'gh pr create.*--body([ =]|$)' skills/n1-pr | grep -q .; then
    echo "FAIL: a gh pr create line in skills/n1-pr inlines --body"; FAIL=1
else
    echo "PASS: every gh pr create in skills/n1-pr uses --body-file"
fi
GUARD='case "$PR_BODY_FILE" in "$N1_HOME"/scratch/pr-body-*/*) echo "PR body path invalid"; exit 1;; "$N1_HOME"/scratch/pr-body-*) ;;'
if grep -qF "$GUARD" "$P1" && grep -qF "$GUARD" "$P2"; then
    echo "PASS: PR_BODY_FILE path is validated before use (no subpath after prefix)"
else
    echo "FAIL: PR_BODY_FILE path not validated in 01/02"; FAIL=1
fi

# 11. N1-138/N1-405: codex-triage scratch paths are prefix-checked (no subpath) before mv / rm
CT=skills/n1-pr/procedures/codex-triage.md
TT=$(mktemp -d); trap 'rm -rf "$TT"' EXIT
mkdir -p "$TT/home/scratch"
awk '/^### Triage File/{f=1} f&&/^```bash/{g=1;next} g&&/^```/{exit} g' "$CT" \
    | sed -E -e '/^source ~\/\.n1\/preamble\.sh$/d' -e "s/^([A-Z_]+)='<.*>'\$/\1=\"\${V_\1}\"/" > "$TT/save.sh"
export N1_HOME="$TT/home"
SC="$TT/home/scratch"; K=me_T-1
mkfiles() { rm -rf "$SC" "$TT/home/memory"; mkdir -p "$SC/codex-validate-$1.v"; printf 'body\n' > "$SC/codex-triage-$1.t"; }
runsave() { V_ID="${3-T-1}" V_KEY=$K V_TRIAGE_FILE="$1" V_VALIDATE_DIR="$2" bash "$TT/save.sh"; }
mkfiles $K
out=$(runsave "$SC/codex-triage-$K.t" "$SC/codex-validate-$K.v")
if grep -q '^triage:saved file=' <<<"$out" && [ "$(cat "$TT/home/memory/T-1/codex-triage.md" 2>/dev/null)" = body ] && [ -z "$(ls -A "$SC")" ]; then
    echo "PASS: codex-triage moves the triage file to memory and removes the matching state dir"
else echo "FAIL: codex-triage save: $out"; FAIL=1; fi
mkfiles other_T-2
out=$(runsave "$SC/codex-triage-other_T-2.t" "$SC/codex-validate-other_T-2.v")
if grep -q '^triage:bad-path$' <<<"$out" && [ -e "$SC/codex-triage-other_T-2.t" ] && [ -d "$SC/codex-validate-other_T-2.v" ] && [ ! -e "$TT/home/memory/T-1/codex-triage.md" ]; then
    echo "PASS: codex-triage leaves other-branch paths alone"
else echo "FAIL: codex-triage touched other-branch paths: $out"; FAIL=1; fi
mkfiles $K; mkdir -p "$SC/codex-triage-$K.d"; : > "$SC/codex-triage-$K.d/x"
out=$(runsave "$SC/codex-triage-$K.d/x" "$SC/codex-validate-$K.v/sub")
if grep -q '^triage:bad-path$' <<<"$out" && [ -e "$SC/codex-triage-$K.d/x" ] && [ -d "$SC/codex-validate-$K.v" ]; then
    echo "PASS: codex-triage rejects subpaths for the triage file and the state dir"
else echo "FAIL: codex-triage accepted a subpath: $out"; FAIL=1; fi
mkfiles $K
out=$(runsave "$SC/codex-triage-$K.t" "" '../x')
if grep -q '^triage:fallback-unavailable file=' <<<"$out" && [ -e "$SC/codex-triage-$K.t" ] && [ ! -e "$TT/home/x" ]; then
    echo "PASS: codex-triage rejects an invalid ticket ID"
else echo "FAIL: codex-triage accepted an invalid ID: $out"; FAIL=1; fi
if grep -nE '^[[:space:]]*(\[ -n .* \] && )?rm -r?f "\$(VALIDATE_DIR|GATE_DIR|TRIAGE_FILE)"' "$CT" >/dev/null; then
    echo "FAIL: an unguarded rm of a scratch placeholder remains in codex-triage"; FAIL=1
else echo "PASS: no unguarded rm of scratch placeholders in codex-triage"; fi

# N1-405: the Scope Gate rebuilds its inputs from the START/BASE literals (SEC-2), records the fix head on push:ok, fails closed,
# writes the blocked-gate marker on kept= (SEC-3) and restores a dirty tree (CR-1)
{ printf '. "%s/lib/codex-review.sh"\n' "$PWD"; awk '/^### Scope Gate/{f=1} f&&/^```bash/{g=1;next} g&&/^```/{exit} g' "$CT" \
    | sed -E -e '/^source /d' -e "s/^([A-Z_]+)='<.*>'\$/\1=\"\${V_\1}\"/"; } > "$TT/gate.sh"
n1_increment_counter() { echo 1; }; n1_head_record() { echo "head-recorded from=$1"; }
export -f n1_increment_counter n1_head_record
mkdir -p "$TT/root/scripts" "$TT/repo"
printf '#!/bin/bash\necho "start=$(cat "$1") allowed=$(cat "$2") patch=$3" > "$GATE_LOG"\necho "${GATE_OUT:-push:ok}"\n' > "$TT/root/scripts/codex-push-gate.sh"
git -C "$TT/repo" init -q
git -C "$TT/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
B0=$(git -C "$TT/repo" rev-parse HEAD)
echo a > "$TT/repo/a.txt"; git -C "$TT/repo" add a.txt; git -C "$TT/repo" -c user.name=t -c user.email=t@t commit -q -m a
git -C "$TT/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m b
S0=$(git -C "$TT/repo" rev-parse HEAD~1); S1=$(git -C "$TT/repo" rev-parse HEAD)
MK="$TT/home/memory/T-1/codex-gate-blocked"
rungate() { # <start> [base] [id]
    (cd "$TT/repo" && V_ID="${3-T-1}" V_START="$1" V_BASE="${2-$B0}" N1_ROOT="$TT/root" N1_HOME="$TT/home" GATE_LOG="$TT/gate.log" bash "$TT/gate.sh")
}
mkdir -p "$SC/codex-gate-$K.g"; echo "$S1" > "$SC/codex-gate-$K.g/start"; printf 'a.txt\nevil.sh\n' > "$SC/codex-gate-$K.g/allowed.txt"
rm -f "$TT/gate.log"; out=$(rungate "$S0")
if grep -qx 'push:ok' <<<"$out" && grep -qx "head-recorded from=$S0" <<<"$out" \
   && grep -qxF "start=$S0 allowed=a.txt patch=$TT/home/memory/T-1/codex-blocked-fix.patch" "$TT/gate.log"; then
    echo "PASS: scope gate rebuilds start/allowed from START and BASE (tampered scratch files ignored), records the fix head on push:ok"
else echo "FAIL: scope gate push:ok path: $out"; FAIL=1; fi
if grep -qE 'scratch/codex-gate|GATE_DIR' "$CT"; then echo "FAIL: codex-triage still reads gate inputs from scratch"; FAIL=1
else echo "PASS: codex-triage keeps no gate inputs in scratch"; fi
for bad in "x" "$S0;id" ""; do
    rm -f "$TT/gate.log" "$MK"; out=$(rungate "$bad")
    if grep -q '^push:blocked paths=gate-unavailable kept=' <<<"$out" && [ ! -e "$TT/gate.log" ]; then echo "PASS: scope gate rejects START '${bad:0:6}'"
    else echo "FAIL: scope gate accepted START '$bad': $out"; FAIL=1; fi
done
rm -f "$TT/gate.log"; out=$(rungate "$S0" "bad;id")
if grep -q '^push:blocked paths=gate-unavailable kept=' <<<"$out" && [ ! -e "$TT/gate.log" ]; then echo "PASS: scope gate rejects an invalid BASE"; else echo "FAIL: invalid BASE accepted: $out"; FAIL=1; fi
rm -f "$MK"; out=$(rungate "$S0" "$B0" "../x")
if grep -q '^push:blocked paths=gate-unavailable kept=' <<<"$out" && [ ! -e "$TT/home/x" ]; then echo "PASS: scope gate rejects an invalid ID"; else echo "FAIL: invalid ID accepted: $out"; FAIL=1; fi
rm -f "$TT/gate.log" "$MK"; out=$(GATE_OUT='push:blocked paths=gate-unavailable' rungate "$S0")
if grep -qx "push:blocked paths=gate-unavailable reset=$S1" <<<"$out" && [ "$(git -C "$TT/repo" rev-parse HEAD)" = "$S0" ] && ! grep -q head-recorded <<<"$out" && [ ! -e "$MK" ]; then
    echo "PASS: gate-unavailable after fix commits resets to the run-start head (fail closed)"
else echo "FAIL: gate-unavailable handling: $out"; FAIL=1; fi
out=$(GATE_OUT='push:blocked paths=gate-unavailable' rungate "$S0")
if [ "$out" = "push:none" ]; then echo "PASS: bare gate-unavailable with no new commit is push:none (CR-2)"; else echo "FAIL: bare gate-unavailable: $out"; FAIL=1; fi
# SEC-3: a failed reset leaves kept= and the marker; a dirty tracked file makes git reset --keep fail
git -C "$TT/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m c; echo changed >> "$TT/repo/a.txt"; git -C "$TT/repo" add a.txt
git -C "$TT/repo" -c user.name=t -c user.email=t@t commit -q -m touch-a; echo dirty >> "$TT/repo/a.txt"
S2=$(git -C "$TT/repo" rev-parse HEAD~2); rm -f "$MK"
out=$(GATE_OUT='push:blocked paths=a.txt kept=abc' rungate "$S2")
if grep -q 'kept=' <<<"$out" && [ "$(cat "$MK" 2>/dev/null)" = "$S2" ]; then echo "PASS: kept= writes the blocked-gate marker with the run-start SHA"; else echo "FAIL: kept= marker: $out"; FAIL=1; fi
# CR-1: tree:dirty edits are saved and removed (the same dirty file as above)
if grep -qx 'tree:dirty' <<<"$out" && grep -q '^tree:restored patch=' <<<"$out" && [ -z "$(git -C "$TT/repo" status --porcelain --untracked-files=no)" ] \
   && grep -q '^+dirty' "$TT/home/memory/T-1/codex-uncommitted.patch"; then
    echo "PASS: scope gate saves and restores away uncommitted tracked edits (tree:dirty)"
else echo "FAIL: tree:dirty handling: $out"; FAIL=1; fi

exit $FAIL
