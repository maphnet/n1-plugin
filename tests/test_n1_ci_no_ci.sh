#!/usr/bin/env bash
# N1-484: a repo with no CI ends the ci step skipped before any sleep or poll; repos with CI poll as before.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FAIL=0
expect() { if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
M=skills/n1-ci/steps/01-monitor.md

# 1. n1-ci probe: the Step 1 reconcile-start block prints ci:none only with no workflow file AND no registered checks.
mkdir -p "$T/bin" "$T/home/scratch"; echo '{}' > "$T/home/config.json"
cat > "$T/bin/gh" <<'EOG'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo deadbeef ;;
  "pr checks") case "${GH_MODE:-}" in
      none) echo "no checks reported on the 'feat/x' branch" >&2; exit 1 ;;
      zero) echo 0 ;;
      two) echo 2 ;;
      *) echo "HTTP 502: Bad Gateway" >&2; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOG
printf '#!/bin/sh\necho "$*" >> "%s/sleep.log"\n' "$T" > "$T/bin/sleep"
chmod +x "$T/bin/gh" "$T/bin/sleep"
BLK=$(awk '/^```bash/{b=1;s="";next} b&&/^```/{if(s~/reconcile:start/){printf "%s",s;exit} b=0;next} b{s=s $0 "\n"}' "$M" \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e 's/<PR number>/7/')
expect "probe lives in the reconcile-start block" yes "$(yn grep -qF 'echo "ci:none"' <<<"$BLK")"
G="$T/g"; git init -q -b feat/x "$G"
run_blk() { (cd "$G" && env -u N1_HEADLESS -u N1_RUN_ID GH_MODE="$1" PATH="$T/bin:$PATH" N1_ROOT="$REPO" CLAUDE_PLUGIN_ROOT="$REPO" N1_HOME="$T/home" bash -c "$BLK" 2>&1); }
probe() { run_blk "$1" | grep -c '^ci:none$'; }
expect "probe keeps the reconcile:start record" 1 "$(run_blk none | grep -c '^reconcile:start file=')"
expect "no workflows + 'no checks reported' -> ci:none" 1 "$(probe none)"
expect "no workflows + zero checks -> ci:none" 1 "$(probe zero)"
expect "no workflows + external checks registered -> poll" 0 "$(probe two)"
expect "no workflows + gh error -> poll (fail-safe)" 0 "$(probe err)"
mkdir -p "$G/.github/workflows"; touch "$G/.github/workflows/README.md"
expect "non-workflow file only -> ci:none" 1 "$(probe none)"
touch "$G/.github/workflows/ci.yml"
expect ".yml workflow -> poll" 0 "$(probe none)"
rm -f "$G/.github/workflows/ci.yml"; touch "$G/.github/workflows/ci.yaml"
expect ".yaml workflow -> poll" 0 "$(probe none)"
touch "$G/.github/workflows/ci.yml"
expect ".yml + .yaml workflows -> poll" 0 "$(probe zero)"
rm -rf "$G/.github"
mkdir -p "$G/.circleci"; touch "$G/.circleci/config.yml"
expect ".circleci + zero checks -> poll" 0 "$(probe zero)"
rm -rf "$G/.circleci"; touch "$G/.gitlab-ci.yml"
expect ".gitlab-ci.yml + no checks reported -> poll" 0 "$(probe none)"
rm -f "$G/.gitlab-ci.yml"; touch "$G/Jenkinsfile"
expect "Jenkinsfile + zero checks -> poll" 0 "$(probe zero)"
rm -f "$G/Jenkinsfile"
expect "other CI config removed -> ci:none" 1 "$(probe zero)"
expect "probe never sleeps" no "$(yn test -s "$T/sleep.log")"

# 2. Step 3 wiring: the skip precedes the first sleep; the poll path is unchanged (AC2).
SKIP='**If Step 1 printed `ci:none`**'
L_SKIP=$(grep -nF "$SKIP" "$M" | head -1 | cut -d: -f1)
L_SLEEP=$(grep -nxF '1. `sleep 15` (initial delay).' "$M" | head -1 | cut -d: -f1)
expect "Step 3 skip paragraph exists" yes "$(yn test -n "$L_SKIP")"
expect "Step 3 skip precedes sleep 15" yes "$( [ -n "$L_SKIP" ] && [ -n "$L_SLEEP" ] && [ "$L_SKIP" -lt "$L_SLEEP" ] && echo yes || echo no)"
SL=$(grep -F "$SKIP" "$M" | head -1)
expect "skip ends as no checks configured" yes "$(yn grep -qF 'no checks configured' <<<"$SL")"
expect "skip: no sleep, no poll, no Step 7a" yes "$(yn grep -qF 'no sleep, no poll, no Step 7a, no fix loop' <<<"$SL")"
expect "skip is not a STOP" no "$(yn grep -qF 'STOP' <<<"$SL")"
for l in '1. `sleep 15` (initial delay).' \
         '2. The poll command — separate command.' \
         '3. No checks or `total=0` → `sleep 30`, re-poll (step 2).' \
         '5. Non-default base, nothing after 2 min → print "No CI on story base: no checks registered on <base> within 2 minutes." and end n1-ci as no checks configured (a skipped CI step): no Step 7a, no fix loop.'; do
    expect "unchanged: ${l:0:40}" yes "$(yn grep -qxF -- "$l" "$M")"
done
expect "unchanged: poll command" yes "$(yn grep -qF '**The poll command** (never print raw check JSON): `gh pr checks <PR#> --json name,bucket,link --jq' "$M")"

# 3. n1-start ci.md: the begin fence reads ci: from pr-result.md; only an exact `ci: none` skips n1-ci.
CI=skills/n1-start/steps/ci.md
RL=$(grep -F 'echo ci:none' "$CI" | head -1)
expect "ci.md: reader sits in the begin fence" yes "$(yn grep -qF 'echo ci:none' < <(grep -A1 -F 'n1_step_begin "ci" 13' "$CI"))"
mkdir -p "$T/home/memory/T-1"; F="$T/home/memory/T-1/pr-result.md"
rd() { N1_HOME="$T/home" ID=T-1 bash -c "$RL" 2>&1; }
printf 'status: complete\nreason: -\npr: 7\npr_url: https://github.com/o/r/pull/7\nbranch: feat/x\nci: none\n' > "$F"
expect "ci.md: ci: none -> marker" ci:none "$(rd)"
printf 'status: complete\nci: none\r\n' > "$F"
expect "ci.md: CRLF ci: none -> marker" ci:none "$(rd)"
printf 'status: complete\nreason: -\npr: 7\nbranch: feat/x\n' > "$F"
expect "ci.md: no ci: line -> no marker" "" "$(rd)"
for v in 'ci: nonexistent' 'ci: none extra' ' ci: none' 'ci:none' 'ci: '; do
    printf 'status: complete\n%s\n' "$v" > "$F"
    expect "ci.md: '$v' -> no marker" "" "$(rd)"
done
rm -f "$F"
expect "ci.md: missing pr-result.md -> no marker" "" "$(rd)"
G2=$(grep -F '**If the begin block printed `ci:none`**' "$CI" || true)
expect "ci.md: ci:none skip guard" yes "$(yn test -n "$G2")"
expect "ci.md: guard ends the step skipped without n1-ci" yes "$(yn grep -qF 'skip n1-ci; run the end block with `skipped`; continue.' <<<"$G2")"
expect "ci.md: prMode guard kept" yes "$(yn grep -qF '**If `prMode` is `"skip"`**' "$CI")"

exit $FAIL
