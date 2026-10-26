#!/usr/bin/env bash
# N1-79: post-PR pushes reconcile the whole PR body once per run via the shared procedure,
# preserving ticked/verified lines and Deployment Actions; every push site wires it in.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
FAIL=0
P=$PWD/references/reconcile-pr-body.md
unset N1_QUEUE_RUN_ID N1_HEADLESS

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first occurrence of a precedes first occurrence of b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
snippet() { # first ```bash block after the heading line $1 in $P
    awk -v h="$1" 'index($0, h) == 1 {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b' "$P" 2>/dev/null
}
capture() { # run the run-start capture snippet, print the "reconcile:start file=" path
    PATH="$T/bin:$PATH" N1_HOME="$T/home" bash -c "$(snippet '**Run-start contract.**' | sed -e '/preamble\.sh/d' -e 's|^PR_NUMBER=.*|PR_NUMBER="7"|')" \
        | sed -n 's/^reconcile:start file=//p'
}

# --- procedure structure
check "procedure has Check section" "^## § Check" "$P"
check "procedure has Dispatch section" "^## § Dispatch" "$P"
check "procedure has Apply section" "^## § Apply" "$P"
check "procedure dispatches tech-writer in reconcile mode" "mode: reconcile" "$P"
check "procedure posts via gh pr edit --body-file" "gh pr edit .*--body-file" "$P"
check "procedure never blocks the run" "body may be stale" "$P"

# --- behavior: § Check and § Apply against a stubbed gh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/scratch"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "pr view")
        case "$*" in
            *headRefName*) echo tb ;;
            *headRefOid*) [ "${GH_META_FAIL:-}" = 1 ] && exit 1; echo "$GH_HEAD $GH_STATE ${GH_AUTHOR:-me}" ;;
            *commits*) echo "aaaaaaa all pr commits" ;;
            *body*) [ "${GH_BODY_FAIL:-}" = 1 ] && exit 1; cat "$GH_BODY" ;;
        esac ;;
    "pr diff")
        if [ "${GH_DIFF_EMPTY:-}" = 1 ]; then
            :
        elif [ "${GH_DIFF_BIG:-}" = 1 ]; then
            printf 'diff --git a/x b/x\n'; head -c 40000 /dev/zero | tr '\0' 'x'; echo
        else
            echo "diff --git a/x b/x"
        fi ;;
    "repo view") echo "o/r" ;;
    "api user") echo "${GH_LOGIN:-me}" ;;
    "pr edit") while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$GH_EDITED"; shift; done ;;
    *)
        case "$1" in
            api) [ "${GH_COMPARE_FAIL:-}" = 1 ] && exit 1; echo "bbbbbbb new commit" ;;
        esac ;;
esac
EOF
chmod +x "$T/bin/gh"
printf '## Summary\r\n- old claim\r\n\r\n## Deployment Actions\r\n\r\n### Before deploy\r\n- [x] `echo done`\r\n- [ ] Manual: set secret K\r\n  - [ ] indented action\r\n\r\n## Verification\r\n- [x] works *(locally verified — curl 200)*\r\n- [ ] plain item\r\n' > "$T/body.md"
SHA1="1111111111111111111111111111111111111111"; SHA2="2222222222222222222222222222222222222222"
export N1_HOME="$T/home" GH_BODY="$T/body.md" GH_EDITED="$T/edited.md" GH_STATE=OPEN GH_HEAD="$SHA1" GH_AUTHOR=me GH_LOGIN=me
unset GH_DIFF_EMPTY GH_COMPARE_FAIL
S="$T/home/scratch/reconcile-start-7.testfile"
run() { PATH="$T/bin:$PATH" bash -c "$(snippet "$1" | sed -e 's|^source ~/.n1/preamble.sh$|source '"$ROOT"'/lib/config.sh|' -e 's|^PR_NUMBER=.*|PR_NUMBER="7"|' -e "s|^ADHOC=.*|ADHOC=\"${2:-}\"|" -e "s|^D=\"<D from the reconcile:run line>\"\$|D=\"${3:-}\"|" -e "s|^START_FILE=.*|START_FILE=\"${4-$S}\"|")"; }
dir_of() { printf '%s\n' "$1" | sed -n 's/^reconcile:run dir=//p'; }

echo "$SHA1" > "$S"
out=$(run "## § Check")
check "check skips when the PR head did not move" "^reconcile:skip$" <(printf '%s\n' "$out")
[ ! -f "$S" ] && echo "PASS: check consumes the start-SHA file" || { echo "FAIL: start-SHA file left behind"; FAIL=1; }

export GH_HEAD="$SHA2"
out=$(run "## § Check")
check "check skips without a start SHA (not ad-hoc)" "^reconcile:skip$" <(printf '%s\n' "$out")

echo "$SHA1" > "$S"; export GH_STATE=MERGED
out=$(run "## § Check")
check "check skips a PR that is no longer open" "^reconcile:skip$" <(printf '%s\n' "$out")
export GH_STATE=OPEN

echo "$SHA1" > "$S"
out=$(run "## § Check")
check "check runs when the PR head moved" "^reconcile:run" <(printf '%s\n' "$out")
D=$(dir_of "$out")
check "old body saved" '^- \[x\] `echo done`$' "$D/old-body.md"
[ "$(grep -c $'\r' "$D/old-body.md" 2>/dev/null)" = "0" ] && echo "PASS: old body is LF-only" || { echo "FAIL: old body kept CR"; FAIL=1; }
check "diff saved" "^diff --git" "$D/diff.patch"
check "full diff saved untruncated" "^diff --git" "$D/diff-full.patch"
check "commits since start come from compare" "^bbbbbbb new commit$" "$D/commits.txt"

# N1-141: § Check advances the reviewed-head pin only when the run started at the pinned head and N1 pushed the new head; never ad-hoc.
git init -q "$T/repo"; echo "$SHA2" > "$T/repo/.git/refs/heads/tb"; cd "$T/repo"
PIN="$T/home/review-pins/o_r_7"; mkdir -p "${PIN%/*}"
SHA3="3333333333333333333333333333333333333333"
echo "$SHA1" > "$PIN"; echo "$SHA1" > "$S"
out=$(run "## § Check")
check "check advances the pin from the pinned head" "^pin:advanced 2222222$" <(printf '%s\n' "$out")
[ "$(cat "$PIN")" = "$SHA2" ] && echo "PASS: pin now equals the new head" || { echo "FAIL: pin not advanced"; FAIL=1; }
echo "$SHA3" > "$PIN"; echo "$SHA1" > "$S"
out=$(run "## § Check")
check "check keeps a pin the run did not start from" "^pin:kept$" <(printf '%s\n' "$out")
[ "$(cat "$PIN")" = "$SHA3" ] && echo "PASS: foreign-start pin unchanged" || { echo "FAIL: foreign-start pin changed"; FAIL=1; }
echo "$SHA1" > "$PIN"; echo "$SHA1" > "$S"; echo "$SHA3" > "$T/repo/.git/refs/heads/tb"
out=$(run "## § Check")
check "check keeps the pin when the head is not N1's local tip" "^pin:kept$" <(printf '%s\n' "$out")
[ "$(cat "$PIN")" = "$SHA1" ] && echo "PASS: foreign head leaves the pin" || { echo "FAIL: foreign head advanced the pin"; FAIL=1; }
echo "$SHA2" > "$T/repo/.git/refs/heads/tb"
out=$(run "## § Check" 1)
[ "$(cat "$PIN")" = "$SHA1" ] && echo "PASS: ad-hoc never advances the pin" || { echo "FAIL: ad-hoc advanced the pin"; FAIL=1; }
rm -f "$PIN" "$S"; cd "$ROOT"

echo "$SHA1" > "$S"
out=$(run "## § Check" 1)
check "ad-hoc check runs without a start SHA" "^reconcile:run" <(printf '%s\n' "$out")
D=$(dir_of "$out")
check "ad-hoc commit list is the whole PR" "^aaaaaaa all pr commits$" "$D/commits.txt"
[ -f "$S" ] && echo "PASS: ad-hoc does not delete an existing start-SHA file" || { echo "FAIL: ad-hoc consumed the start-SHA file"; FAIL=1; }
rm -f "$S"

# (c) ad-hoc author mismatch -> skip, no dispatch
export GH_AUTHOR=someone-else
out=$(run "## § Check" 1)
check "ad-hoc skips a PR you don't own" "^reconcile:skip" <(printf '%s\n' "$out")
export GH_AUTHOR=me

# (e) non-hex START is treated as missing -> not ad-hoc, skip
export GH_HEAD="$SHA2"
echo "not-a-sha" > "$S"
out=$(run "## § Check")
check "invalid start SHA is treated as missing" "^reconcile:skip$" <(printf '%s\n' "$out")
rm -f "$S"

# metadata fetch failure -> reconcile:failed:fetch, start file still consumed
export GH_HEAD="$SHA1"
echo "$SHA1" > "$S"
export GH_META_FAIL=1
out=$(run "## § Check")
check "metadata fetch failure reports reconcile:failed:fetch" "^reconcile:failed:fetch" <(printf '%s\n' "$out")
[ ! -f "$S" ] && echo "PASS: metadata fetch failure still consumes the start file" || { echo "FAIL: start file left behind after metadata fetch failure"; FAIL=1; }
unset GH_META_FAIL

# distinct per-run start files: two captures for the same PR produce distinct files;
# § Check with one leaves the other intact
F1=$(capture); F2=$(capture)
[ -n "$F1" ] && [ -n "$F2" ] && [ "$F1" != "$F2" ] && [ -f "$F1" ] && [ -f "$F2" ] \
    && echo "PASS: two captures for the same PR produce distinct files" \
    || { echo "FAIL: captures did not produce distinct files"; FAIL=1; }
export GH_HEAD="$SHA2"
run "## § Check" "" "" "$F1" >/dev/null
[ ! -f "$F1" ] && [ -f "$F2" ] && echo "PASS: check consumes only the file it was given" || { echo "FAIL: check touched the other run's start file"; FAIL=1; }
rm -f "$F2"

# (a) empty diff -> failed:fetch, no reconcile:run, no leftover scratch dir
echo "$SHA1" > "$S"
before_dirs=$(find "$T/home/scratch" -mindepth 1 -maxdepth 1 -type d | wc -l)
export GH_DIFF_EMPTY=1
out=$(run "## § Check")
check "empty diff fails the fetch" "^reconcile:failed:fetch" <(printf '%s\n' "$out")
[ "${out#*reconcile:run}" = "$out" ] && echo "PASS: empty diff never prints reconcile:run" || { echo "FAIL: empty diff never prints reconcile:run"; FAIL=1; }
after_dirs=$(find "$T/home/scratch" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$before_dirs" = "$after_dirs" ] && echo "PASS: empty diff leaves no scratch dir" || { echo "FAIL: empty diff left a scratch dir"; FAIL=1; }
unset GH_DIFF_EMPTY
rm -f "$S"

# (c) diff over 30KB -> diff.patch truncated, diff-full.patch complete
echo "$SHA1" > "$S"
export GH_DIFF_BIG=1
out=$(run "## § Check")
check "big diff still runs" "^reconcile:run" <(printf '%s\n' "$out")
D=$(dir_of "$out")
check "truncated diff carries the truncation marker" "truncated: first 30KB" "$D/diff.patch"
[ "$(wc -c < "$D/diff.patch")" -le 30200 ] && echo "PASS: diff.patch stays near the 30KB cap" || { echo "FAIL: diff.patch exceeds the 30KB cap"; FAIL=1; }
[ "$(wc -c < "$D/diff-full.patch")" -gt 30000 ] && echo "PASS: diff-full.patch keeps the untruncated diff" || { echo "FAIL: diff-full.patch was truncated"; FAIL=1; }
unset GH_DIFF_BIG
rm -rf "$D" "$S"

# (b) compare fails -> commits.txt falls back to pr view commits
echo "$SHA1" > "$S"
export GH_COMPARE_FAIL=1
out=$(run "## § Check")
check "check runs despite a failed compare" "^reconcile:run" <(printf '%s\n' "$out")
D=$(dir_of "$out")
check "failed compare falls back to the whole PR commit list" "^aaaaaaa all pr commits$" "$D/commits.txt"
unset GH_COMPARE_FAIL

# § Apply: revised body drops a ticked line -> aborted, PR untouched
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply aborts when a ticked line is dropped" "^reconcile:aborted" <(printf '%s\n' "$out")
check "apply names the dropped line" '^- \[x\] `echo done`$' <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: aborted apply never edits the PR" || { echo "FAIL: aborted apply edited the PR"; FAIL=1; }
[ ! -d "$D" ] && echo "PASS: apply removes its scratch dir" || { echo "FAIL: scratch dir left behind"; FAIL=1; }

# § Apply: unticked Deployment Actions item dropped -> aborted
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when a Deployment Actions item is dropped" "^reconcile:aborted" <(printf '%s\n' "$out")

# (f) indented Deployment Actions item dropped -> aborted
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when an indented Deployment Actions item is dropped" "^reconcile:aborted" <(printf '%s\n' "$out")
check "apply names the dropped indented line" 'indented action' <(printf '%s\n' "$out")

# § Apply: preserved lines intact, plain item reworded, new action appended -> applied
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n  - [ ] indented action\n- [ ] Manual: set env var NEW_VAR in the deploy environment\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n- [ ] reworded item\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply edits the PR when preserved lines survive" "^reconcile:applied:#7$" <(printf '%s\n' "$out")
check "applied body is the revised body" '^- \[ \] reworded item$' "$GH_EDITED"

# § Apply: empty revised body (tech-writer failed) -> failed, no edit
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
: > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply refuses an empty body" "^reconcile:failed" <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: empty body never edits the PR" || { echo "FAIL: empty body edited the PR"; FAIL=1; }

# (a) § Apply: the re-fetch returns a different body (concurrent edit) -> aborted, no edit
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
cp "$T/body.md" "$T/body.orig.md"
printf '## Summary\r\n- edited concurrently\r\n' > "$T/body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply aborts when the PR body changed during reconcile" "^reconcile:aborted — PR body changed during reconcile" <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: concurrent-edit abort never edits the PR" || { echo "FAIL: concurrent-edit abort edited the PR"; FAIL=1; }
cp "$T/body.orig.md" "$T/body.md"

# (b) § Apply: the re-fetch fails -> aborted, no edit
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
export GH_BODY_FAIL=1
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply aborts when the re-fetch fails" "^reconcile:aborted — PR body changed during reconcile" <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: failed re-fetch never edits the PR" || { echo "FAIL: failed re-fetch edited the PR"; FAIL=1; }
unset GH_BODY_FAIL

# --- narrowed freeze: plain [x] lines outside Deployment Actions may be reworded,
# only Deployment Actions checkboxes and annotated lines stay frozen verbatim
ORIG_GH_BODY="$GH_BODY"
NB="$T/narrow-body.md"
printf '## Summary\n- old claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [x] `bash tests/test_reconcile_pr_body.sh` — 58 PASS\n- [x] works *(locally verified — curl 200)*\n' > "$NB"
export GH_BODY="$NB"
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- old claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [x] `bash tests/test_reconcile_pr_body.sh` — 78 PASS\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "plain [x] line outside Deployment Actions may be reworded" "^reconcile:applied:#7$" <(printf '%s\n' "$out")
[ -f "$GH_EDITED" ] && echo "PASS: reworded plain ticked line still triggers gh pr edit" || { echo "FAIL: gh pr edit not called for reworded plain ticked line"; FAIL=1; }

# a *(locally verified — ...)* annotated line changed -> aborted
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- old claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [x] `bash tests/test_reconcile_pr_body.sh` — 58 PASS\n- [x] works *(locally verified — curl 500)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when an annotated verified line is changed" "^reconcile:aborted" <(printf '%s\n' "$out")

# a ticked Deployment Actions line changed -> aborted
export GH_BODY="$ORIG_GH_BODY"
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo changed`\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when a ticked Deployment Actions line is changed" "^reconcile:aborted" <(printf '%s\n' "$out")

# a plain [x] line unticked -> tick count drops -> aborted with the unticked/dropped message
export GH_BODY="$NB"
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- old claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [ ] `bash tests/test_reconcile_pr_body.sh` — 58 PASS\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when a plain ticked line is unticked" "^reconcile:aborted — revised body unticked or dropped checked items" <(printf '%s\n' "$out")

# a plain [x] line removed entirely -> tick count drops -> aborted
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- old claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply" "" "$D")
check "apply aborts when a plain ticked line is removed" "^reconcile:aborted — revised body unticked or dropped checked items" <(printf '%s\n' "$out")

# --- stray </content> wrapper line
export GH_BODY="$ORIG_GH_BODY"
echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n</content>\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply strips a trailing </content> wrapper line" "^reconcile:applied:#7$" <(printf '%s\n' "$out")
if grep -qxF '</content>' "$GH_EDITED"; then echo "FAIL: trailing </content> line was posted"; FAIL=1; else echo "PASS: trailing </content> line stripped before posting"; fi

echo "$SHA1" > "$S"
out=$(run "## § Check" 1); D=$(dir_of "$out")
printf '## Summary\n- new claim\n</content>\nmore text\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n  - [ ] indented action\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$D")
check "apply edits the PR when </content> appears mid-body" "^reconcile:applied:#7$" <(printf '%s\n' "$out")
check "mid-body </content> line is preserved" '^</content>$' "$GH_EDITED"

# --- N1-138: placeholder paths outside their mktemp prefix, or prefix + subpath, are refused before cat/rm/gh
export GH_HEAD="$SHA2"
DECOY="$T/decoy-start"; echo "$SHA1" > "$DECOY"
mkdir -p "$T/home/scratch/reconcile-start-7.x"; SUBF="$T/home/scratch/reconcile-start-7.x/sub"; echo "$SHA1" > "$SUBF"
for f in "$DECOY" "$SUBF"; do
    out=$(run "## § Check" "" "" "$f"); rc=$?
    if [ "$rc" -ne 0 ] && [ -f "$f" ] && [ "${out#*reconcile:run}" = "$out" ] && grep -q '^reconcile:failed:bad-path' <<<"$out"; then
        echo "PASS: check refuses START_FILE $f and leaves it in place"
    else
        echo "FAIL: check used START_FILE $f"; FAIL=1
    fi
done
out=$(run "## § Check" 1 "" "")
check "ad-hoc check still runs with an empty START_FILE" "^reconcile:run" <(printf '%s\n' "$out")
rm -rf "$(dir_of "$out")"

mk_apply_dir() { mkdir -p "$1"; tr -d '\r' < "$GH_BODY" > "$1/old-body.md"; cp "$1/old-body.md" "$1/new-body.md"; }
# positive control: the same fixture in a valid dir applies, so the refusals below come from the guard alone
OK="$T/home/scratch/reconcile-7.ok"; mk_apply_dir "$OK"; rm -f "$GH_EDITED"
out=$(run "## § Apply" "" "$OK")
check "apply accepts a D inside reconcile-<PR>." "^reconcile:applied:#7$" <(printf '%s\n' "$out")
[ ! -d "$OK" ] && echo "PASS: valid D is removed after apply" || { echo "FAIL: valid D left behind"; FAIL=1; }
for d in "$T/decoy-dir" "$T/home/scratch/reconcile-7.x/sub" "$T/home/scratch/reconcile-start-7.y"; do
    mk_apply_dir "$d"; rm -f "$GH_EDITED"
    out=$(run "## § Apply" "" "$d"); rc=$?
    if [ "$rc" -ne 0 ] && [ -d "$d" ] && [ ! -f "$GH_EDITED" ] && grep -q '^reconcile:failed:bad-path' <<<"$out"; then
        echo "PASS: apply refuses D $d (no edit, no rm)"
    else
        echo "FAIL: apply used D $d"; FAIL=1
    fi
done

# --- tech-writer reconcile mode
TW=agents/tech-writer.md
check "tech-writer input declares mode create|reconcile" '^- `mode`: `create` \(default\) or `reconcile`' "$TW"
check "tech-writer has a Reconcile Mode section" "^## Reconcile Mode" "$TW"
before "reconcile skip line precedes Phase 1 Step 1" "skip Phase 1 and Phase 2" "### Step 1: Extract Change Footprint" "$TW"
check "reconcile copies Deployment Actions verbatim, never regenerates" "Never regenerate it" "$TW"
check "reconcile dedupes newly-detected deploy actions against the old body" "not already present" "$TW"
check "reconcile preserves locally verified lines" "locally verified" "$TW"
check "reconcile preservation rule scopes checkbox freeze to Deployment Actions" "inside .## Deployment Actions." "$TW"
check "reconcile allows rewording stale plain ticked lines" "may be reworded when the diff makes their stated fact stale" "$TW"
check "reconcile output has no wrapper tags" "no other wrapper tags" "$TW"
check "reconcile passes unknown sections through" "outside the known set" "$TW"
check "reconcile notes stale docs instead of editing" "not updated \(reconcile mode\)" "$TW"
check "reconcile checks claims against the full diff" "full diff" "$TW"

# --- push-site wiring
C1=skills/n1-ci/steps/01-monitor.md; C2=skills/n1-ci/steps/02-fix.md
check "n1-ci records the run-start PR head" "reconcile-start-" "$C1"
before "n1-ci reconciles before finish chaining" "Step 7a" "Finish chaining" "$C1"
check "n1-ci Step 7a follows the procedure" "reconcile-pr-body\.md" "$C2"
before "n1-ci reconcile precedes the final report" "### Step 7a" "### Final report" "$C2"
check "n1-ci NOT_BRANCH_CAUSED abort still runs Step 7a first" "Abort.*run \*\*Step 7a\*\*" "$C2"
check "n1-ci no-checks-appeared STOP runs Step 7a first" "run \*\*Step 7a\*\*.*No CI checks appeared" "$C1"
check "n1-ci pending-budget-exhaustion STOP runs Step 7a first" "run \*\*Step 7a\*\*.*Wait longer or skip" "$C1"
CP=skills/n1-pr/procedures/codex-triage.md
check "codex triage records the PR head" "reconcile-start-" "$CP"
before "codex triage capture precedes developer dispatch" "reconcile-start-" "**Developer instructions:**" "$CP"
before "codex triage reconcile follows the fix-cycle counter" "cross_host_fix_cycle" "reconcile-pr-body.md" "$CP"
before "codex triage reconcile precedes Triage Reply" "reconcile-pr-body.md" "### Triage Reply" "$CP"
# (f) sentinel: the maxFixAttempts exit routes to Reconcile PR Body, not straight to Triage Reply
check "codex triage maxFixAttempts exit routes to Reconcile PR Body" "proceed to \*\*Reconcile PR Body\*\* below" "$CP"
if grep -qE "maxFixAttempts\`, proceed to Triage Reply" "$CP"; then
    echo "FAIL: maxFixAttempts exit still jumps straight to Triage Reply"; FAIL=1
else
    echo "PASS: maxFixAttempts exit no longer jumps straight to Triage Reply"
fi
check "codex triage dispatch-failure exit also reconciles before Triage Reply" "still proceed to \*\*Reconcile PR Body\*\* below" "$CP"
RR=skills/n1-review-response/steps/02-resolve.md
check "review-response records the PR head" "reconcile-start-" "$RR"
before "review-response capture precedes developer dispatch" "reconcile-start-" "**Developer instructions:**" "$RR"
before "review-response reconcile precedes 6b" "reconcile-pr-body.md" "### 6b" "$RR"
check "review-response reconciles even if the developer dispatch fails" "even if it errors, times out, or returns empty output, still run the reconcile" "$RR"

# --- ad-hoc rule and docs
check "HOST ROUTING covers ad-hoc pushes to an open PR" 'PR BODY RECONCILE:.*references/reconcile-pr-body\.md.*ADHOC=1' hooks/session-start.sh
check "architecture.md documents the procedure" "references/reconcile-pr-body\.md" references/architecture.md

exit $FAIL
