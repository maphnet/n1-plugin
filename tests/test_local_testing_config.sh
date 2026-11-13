#!/usr/bin/env bash
# tests/test_local_testing_config.sh
# NP-222: local-testing mode resolution precedence and worktree.copyFiles copy rules.
# Run: bash tests/test_local_testing_config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/config.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "$expected" "$actual"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export N1_HOME="$T/home"
mkdir -p "$N1_HOME"
cfg() { printf '%s\n' "$1" > "$N1_HOME/config.json"; }

# ---- Mode resolution (N1-559: live | smoke | none; legacy mode "test" ignored) ----
REPO="$T/repo"; mkdir -p "$REPO"
mode() { n1_resolve_local_testing_mode "$REPO"; }

cfg '{}'
assert_eq "M1: empty config, no compose -> none" "none" "$(mode)"
touch "$REPO/compose.yml"
assert_eq "M2: compose present, autoLive absent -> none" "none" "$(mode)"
cfg '{"localTesting":{"autoLive":false}}'
assert_eq "M3: explicit autoLive false + compose -> none" "none" "$(mode)"
cfg '{"localTesting":{"autoLive":true}}'
assert_eq "M4: autoLive true + compose.yml -> live" "live" "$(mode)"
cfg '{"localTesting":{"autoLive":true,"mode":"test"}}'
assert_eq "M5: legacy mode test is ignored, autoLive + compose -> live" "live" "$(mode)"
cfg '{"localTesting":{"mode":"smoke"}}'
assert_eq "M6: explicit smoke passes through" "smoke" "$(mode)"
cfg '{"localTesting":{"mode":"live"}}'
assert_eq "M6b: explicit live passes through" "live" "$(mode)"
cfg '{"localTesting":{"mode":"test"}}'
assert_eq "M6c (AC7): legacy mode test alone -> none" "none" "$(mode)"
cfg '{"localTesting":{"mode":"bogus"}}'
assert_eq "M6d: unknown mode value ignored -> none" "none" "$(mode)"
rm "$REPO/compose.yml"
cfg '{"localTesting":{"autoLive":true}}'
assert_eq "M7: autoLive true, no compose -> none" "none" "$(mode)"
touch "$REPO/docker-compose.yaml"
assert_eq "M8: autoLive true + docker-compose.yaml -> live" "live" "$(mode)"
rm "$REPO/docker-compose.yaml"
cfg '{"localTesting":{"startCommand":"npm run dev"}}'
assert_eq "M9: startCommand still infers live (unchanged)" "live" "$(mode)"
cfg '{"localTesting":{"mode":"test","startCommand":"npm run dev"}}'
assert_eq "M10: legacy mode test + startCommand -> live" "live" "$(mode)"

# ---- Start-command detection (N1-559; mirrors n1-init step 08 Startup Detection) ----
D="$T/det"; mkdir -p "$D"
det() { n1_detect_start_command "$D" || true; }
assert_eq "D1: nothing detectable -> empty" "" "$(det)"
printf 'build:\n\ttrue\nserve:\n\ttrue\n' > "$D/Makefile"
assert_eq "D2: Makefile serve target" "make serve" "$(det)"
rm "$D/Makefile"
printf '{"scripts":{"start":"node a.js","dev":"vite"}}' > "$D/package.json"
assert_eq "D3: package.json prefers dev" "npm run dev" "$(det)"
printf '{"scripts":{"start":"node a.js"}}' > "$D/package.json"
assert_eq "D4: package.json start" "npm start" "$(det)"
printf '{"dependencies":{"dev":"1.0.0"}}' > "$D/package.json"
assert_eq "D5: a dependency named dev is not a script" "" "$(det)"
rm "$D/package.json"; touch "$D/manage.py"
assert_eq "D6: manage.py" "python manage.py runserver" "$(det)"
rm "$D/manage.py"; printf 'worker: celery\nweb: gunicorn app:app\n' > "$D/Procfile"
assert_eq "D7: Procfile web line" "gunicorn app:app" "$(det)"
printf 'worker: celery\n' > "$D/Procfile"
assert_eq "D8: Procfile without web line" "heroku local" "$(det)"
touch "$D/compose.yaml"
assert_eq "D9: compose outranks every other match" "docker compose up -d" "$(det)"
rm -f "$D/compose.yaml" "$D/Procfile"

# ---- Live-testing offer decision and write (N1-559) ----
O="$T/offer"; mkdir -p "$O"; touch "$O/compose.yml"
offer() { n1_local_testing_offer "$O"; }
cfg '{"localTesting":{"enabled":true}}'
assert_eq "O1 (AC1): enabled, autoLive absent, compose -> compose offer" "compose" "$(offer)"
cfg '{}'
assert_eq "O2: default config + compose -> compose offer" "compose" "$(offer)"
cfg '{"localTesting":{"autoLive":false}}'
assert_eq "O3 (AC2): explicit autoLive false -> never offered" "" "$(offer)"
cfg '{"localTesting":{"autoLive":true}}'
assert_eq "O4: live already resolves -> no offer" "" "$(offer)"
cfg '{"localTesting":{"enabled":false}}'
assert_eq "O5: disabled -> no offer" "" "$(offer)"
cfg '{"localTesting":{"mode":"smoke"}}'
assert_eq "O6: smoke -> no offer" "" "$(offer)"
cfg '{"localTesting":{"enabled":true,"mode":"test"}}'
assert_eq "O7 (AC8): legacy mode test + compose -> compose offer" "compose" "$(offer)"
n1_local_testing_offer_write compose
assert_eq "O8 (AC8): Yes writes autoLive true" "true" "$(n1_config_val '.localTesting.autoLive')"
assert_eq "O9 (AC8): Yes deletes legacy mode test" "" "$(n1_config_val '.localTesting.mode')"
assert_eq "O10 (AC8): resolver now returns live" "live" "$(n1_resolve_local_testing_mode "$O")"
assert_eq "O11: Yes keeps other keys" "true" "$(n1_config_val '.localTesting.enabled')"
cfg '{"localTesting":{"enabled":true}}'
n1_local_testing_offer_write no
assert_eq "O12 (AC1): No writes autoLive false and the offer is gone" "false|" "$(n1_config_val '.localTesting.autoLive')|$(offer)"
cfg '{"localTesting":{"mode":"smoke"}}'
n1_local_testing_offer_write no
assert_eq "O13: No never deletes an explicit mode" "smoke" "$(n1_config_val '.localTesting.mode')"
rm "$O/compose.yml"; printf '{"scripts":{"dev":"vite"}}' > "$O/package.json"
cfg '{"localTesting":{"mode":"test"}}'
assert_eq "O14 (AC3): no compose, start script -> startCommand offer" "start:npm run dev" "$(offer)"
n1_local_testing_offer_write 'start:npm run dev -- --port 5173'
assert_eq "O15 (AC3): Yes writes startCommand verbatim" "npm run dev -- --port 5173" "$(n1_config_val '.localTesting.startCommand')"
assert_eq "O16 (AC3): resolver live after startCommand write" "live" "$(n1_resolve_local_testing_mode "$O")"
rm "$O/package.json"; cfg '{}'
assert_eq "O17: no runnable service -> no offer" "" "$(offer)"
assert_eq "O18: invalid answer is rejected" "1" "$(n1_local_testing_offer_write maybe; echo $?)"
assert_eq "O19: invalid answer leaves config untouched" "{}" "$(cat "$N1_HOME/config.json")"

# ---- worktree.copyFiles ----
SRC="$T/a/src"; WT="$T/b/wt"
mkdir -p "$SRC/nested" "$WT"
git -C "$WT" init -q
printf '.env\n.env.local\n' > "$WT/.gitignore"
echo secret > "$SRC/.env"
echo local > "$SRC/nested/.env.local"
echo plain > "$SRC/notignored.txt"
echo out > "$T/a/escape"
echo abs > "$T/a/abs.env"
cfg "{\"worktree\":{\"copyFiles\":[\".env\",\"nested/.env.local\",\"missing.env\",\"notignored.txt\",\"../escape\",\"$T/a/abs.env\"]}}"

assert_eq "C1: copies only present, ignored, safe entries" "2" "$(n1_copy_worktree_files "$SRC" "$WT" 2>/dev/null)"
assert_eq "C2: .env content copied" "secret" "$(cat "$WT/.env")"
assert_eq "C3: nested entry copied" "local" "$(cat "$WT/nested/.env.local")"
assert_eq "C4: non-ignored file skipped" "no" "$([ -e "$WT/notignored.txt" ] && echo yes || echo no)"
assert_eq "C5: '..' and absolute entries rejected explicitly" "2" "$(n1_copy_worktree_files "$SRC" "$WT" 2>&1 >/dev/null | grep -c 'rejected')"
assert_eq "C6: nothing written outside the worktree" "no" "$([ -e "$T/b/escape" ] || [ -e "$WT$T" ] && echo yes || echo no)"
echo changed > "$SRC/.env"
assert_eq "C7: re-run copies nothing (missing-only)" "0" "$(n1_copy_worktree_files "$SRC" "$WT" 2>/dev/null)"
assert_eq "C8: existing destination not overwritten" "secret" "$(cat "$WT/.env")"
assert_eq "C9: copied files invisible to git (never committed)" "?? .gitignore" "$(git -C "$WT" status --porcelain)"
cfg '{}'
assert_eq "C10: no copyFiles key -> 0" "0" "$(n1_copy_worktree_files "$SRC" "$WT")"

# ---- Wiring (N1-559) ----
R="$SCRIPT_DIR/.."
LT="$R/skills/n1-start/steps/local-testing.md"
SENT='Local testing: not run — no live verification configured for this project'
ln_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || true; }  # || true: no match must not abort under set -e/pipefail
NLV=$(ln_of "$LT" '"skip_reason":"no_live_verification"')
RUN=$(ln_of "$LT" 'read `procedures/local-testing-run.md`')
assert_eq "W1 (AC5): no_live_verification skip precedes the planner/developer procedure" "yes" \
  "$([ -n "$NLV" ] && [ -n "$RUN" ] && [ "$NLV" -lt "$RUN" ] && echo yes || echo no)"
assert_eq "W2 (AC4): offer never asks when headless" "1" "$(grep -cF 'Headless (`N1_HEADLESS=1`): do not ask' "$LT")"
assert_eq "W3 (AC1): step calls the offer helper" "1" "$(grep -cF 'n1_local_testing_offer "$LT_ROOT"' "$LT")"
assert_eq "W4 (AC7): QA dedup gate removed from the step" "0" "$(grep -cE 'qa_dedup|QA_DEDUP_SKIP' "$LT")"
assert_eq "W5 (AC6): stub sentence written by the step" "1" "$(grep -cF "$SENT" "$LT")"
assert_eq "W6 (AC7): planner has no test-mode branch" "0" "$(grep -cF '"test"' "$R/agents/local-test-planner.md")"
assert_eq "W7 (AC7): run procedure has no test-mode branch" "0" "$(grep -cF 'If mode is `test`' "$R/skills/n1-start/procedures/local-testing-run.md")"
assert_eq "W8 (AC6): tech-writer uses the not-run first line as the summary line" "1" \
  "$(grep -cF 'first line starts with `Local testing: not run`' "$R/agents/tech-writer.md")"
assert_eq "W9 (AC6): Gate 3 rule names the exact sentence" "1" \
  "$(grep -cF "$SENT" "$R/skills/n1-start/procedures/output-gates.md")"

echo; echo "Passed: $PASS  Failed: $FAIL"; [ "$FAIL" -eq 0 ]
