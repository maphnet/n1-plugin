#!/usr/bin/env bash
# N1-79: post-PR pushes reconcile the whole PR body once per run via the shared procedure,
# preserving ticked/verified lines and Deployment Actions; every push site wires it in.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
P=references/reconcile-pr-body.md
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
            *headRefOid*) echo "$GH_HEAD $GH_STATE" ;;
            *commits*) echo "aaaaaaa all pr commits" ;;
            *body*) cat "$GH_BODY" ;;
        esac ;;
    "pr diff") echo "diff --git a/x b/x" ;;
    "api "*) echo "bbbbbbb new commit" ;;
    "pr edit") while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && cp "$2" "$GH_EDITED"; shift; done ;;
esac
EOF
chmod +x "$T/bin/gh"
printf '## Summary\r\n- old claim\r\n\r\n## Deployment Actions\r\n\r\n### Before deploy\r\n- [x] `echo done`\r\n- [ ] Manual: set secret K\r\n\r\n## Verification\r\n- [x] works *(locally verified — curl 200)*\r\n- [ ] plain item\r\n' > "$T/body.md"
export N1_HOME="$T/home" GH_BODY="$T/body.md" GH_EDITED="$T/edited.md" GH_STATE=OPEN GH_HEAD=sha1
D="$T/home/scratch/reconcile-7"
S="$T/home/scratch/reconcile-start-7.sha"
run() { PATH="$T/bin:$PATH" bash -c "$(snippet "$1" | sed -e '/preamble\.sh/d' -e 's|^PR_NUMBER=.*|PR_NUMBER="7"|' -e "s|^ADHOC=.*|ADHOC=\"${2:-}\"|")"; }

echo sha1 > "$S"
out=$(run "## § Check")
check "check skips when the PR head did not move" "^reconcile:skip$" <(printf '%s\n' "$out")
[ ! -f "$S" ] && echo "PASS: check consumes the start-SHA file" || { echo "FAIL: start-SHA file left behind"; FAIL=1; }

export GH_HEAD=sha2
out=$(run "## § Check")
check "check skips without a start SHA (not ad-hoc)" "^reconcile:skip$" <(printf '%s\n' "$out")

echo sha1 > "$S"; export GH_STATE=MERGED
out=$(run "## § Check")
check "check skips a PR that is no longer open" "^reconcile:skip$" <(printf '%s\n' "$out")
export GH_STATE=OPEN

echo sha1 > "$S"
out=$(run "## § Check")
check "check runs when the PR head moved" "^reconcile:run" <(printf '%s\n' "$out")
check "old body saved" '^- \[x\] `echo done`$' "$D/old-body.md"
[ "$(grep -c $'\r' "$D/old-body.md" 2>/dev/null)" = "0" ] && echo "PASS: old body is LF-only" || { echo "FAIL: old body kept CR"; FAIL=1; }
check "diff saved" "^diff --git" "$D/diff.patch"
check "commits since start come from compare" "^bbbbbbb new commit$" "$D/commits.txt"

out=$(run "## § Check" 1)
check "ad-hoc check runs without a start SHA" "^reconcile:run" <(printf '%s\n' "$out")
check "ad-hoc commit list is the whole PR" "^aaaaaaa all pr commits$" "$D/commits.txt"

# § Apply: revised body drops a ticked line -> aborted, PR untouched
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [ ] Manual: set secret K\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply")
check "apply aborts when a ticked line is dropped" "^reconcile:aborted" <(printf '%s\n' "$out")
check "apply names the dropped line" '^- \[x\] `echo done`$' <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: aborted apply never edits the PR" || { echo "FAIL: aborted apply edited the PR"; FAIL=1; }
[ ! -d "$D" ] && echo "PASS: apply removes its scratch dir" || { echo "FAIL: scratch dir left behind"; FAIL=1; }

# § Apply: unticked Deployment Actions item dropped -> aborted
run "## § Check" 1 >/dev/null
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n' > "$D/new-body.md"
out=$(run "## § Apply")
check "apply aborts when a Deployment Actions item is dropped" "^reconcile:aborted" <(printf '%s\n' "$out")

# § Apply: preserved lines intact, plain item reworded, new action appended -> applied
run "## § Check" 1 >/dev/null
printf '## Summary\n- new claim\n\n## Deployment Actions\n\n### Before deploy\n- [x] `echo done`\n- [ ] Manual: set secret K\n- [ ] Manual: set env var NEW_VAR in the deploy environment\n\n## Verification\n- [x] works *(locally verified — curl 200)*\n- [ ] reworded item\n' > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply")
check "apply edits the PR when preserved lines survive" "^reconcile:applied:#7$" <(printf '%s\n' "$out")
check "applied body is the revised body" '^- \[ \] reworded item$' "$GH_EDITED"

# § Apply: empty revised body (tech-writer failed) -> failed, no edit
run "## § Check" 1 >/dev/null
: > "$D/new-body.md"
rm -f "$GH_EDITED"
out=$(run "## § Apply")
check "apply refuses an empty body" "^reconcile:failed" <(printf '%s\n' "$out")
[ ! -f "$GH_EDITED" ] && echo "PASS: empty body never edits the PR" || { echo "FAIL: empty body edited the PR"; FAIL=1; }

exit $FAIL
