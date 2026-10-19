#!/usr/bin/env bash
# N1-71: n1_wait_release_runs counts only release-event runs, retries gh errors, and never reads them as a deploy failure.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0

expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}
has_line() { # <label> <exact-line> <text>
    if grep -qxF -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 (no line '$2' in '$3')"; FAIL=1; fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# Fake gh: "run list" filters the $GH_RUNS fixture by --event/--workflow like the real CLI.
# The first $GH_FAIL_FIRST calls fail like a TLS handshake timeout.
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "$GH_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GH_COUNT"
[ "$n" -le "${GH_FAIL_FIRST:-0}" ] && { echo "net/http: TLS handshake timeout" >&2; exit 1; }
[ "$1 $2" = "run list" ] || exit 1
ev="" wf=""
while [ $# -gt 0 ]; do
    case "$1" in --event) ev="$2" ;; --workflow) wf="$2" ;; esac
    shift
done
jq -c --arg ev "$ev" --arg wf "$wf" \
    '[.[] | select(($ev == "" or .event == $ev) and ($wf == "" or .workflowName == $wf)) | {status, conclusion, url}]' <<<"$GH_RUNS"
EOF
printf '#!/usr/bin/env bash\n:\n' > "$T/bin/sleep"   # no-op: the 30s poll interval must not slow the test
chmod +x "$T/bin/gh" "$T/bin/sleep"

watch() { # <fail-first> <runs-json> <grace> <max-minutes> [workflow] -> helper stdout
    rm -f "$T/count"
    GH_FAIL_FIRST="$1" GH_RUNS="$2" GH_COUNT="$T/count" PATH="$T/bin:$PATH" \
        bash -c 'source lib/poll.sh; n1_wait_release_runs abc123 "$@"' _ "${@:3}"
}
first() { printf '%s' "${1%%$'\n'*}"; }

R='https://github.com/o/r/actions/runs'
PUSH_DONE='{"event":"push","workflowName":"Deploy Prod","status":"completed","conclusion":"success","url":"'$R'/1"}'
REL_RUNNING='{"event":"release","workflowName":"Deploy Prod","status":"in_progress","conclusion":"","url":"'$R'/2"}'
REL_OK='{"event":"release","workflowName":"Deploy Prod","status":"completed","conclusion":"success","url":"'$R'/3"}'
REL_SKIP='{"event":"release","workflowName":"Notify","status":"completed","conclusion":"skipped","url":"'$R'/4"}'
REL_FAIL='{"event":"release","workflowName":"Notify","status":"completed","conclusion":"failure","url":"'$R'/5"}'

out=$(watch 0 "[$PUSH_DONE]" 0 0)
expect "stale push-event run on the same commit is not a deploy -> none" "none" "$(first "$out")"

out=$(watch 0 "[]" 0 0)
expect "no runs after grace -> none" "none" "$(first "$out")"

out=$(watch 0 "[$PUSH_DONE,$REL_RUNNING]" 0 0)
expect "release run in progress at chunk end -> pending" "pending" "$(first "$out")"
has_line "pending lists the running run URL" "in_progress $R/2" "$out"

out=$(watch 0 "[$REL_OK,$REL_SKIP]" 0 0)
expect "all release runs success/skipped -> success" "success" "$(first "$out")"
has_line "success lists the run URL" "success $R/3" "$out"

out=$(watch 0 "[$REL_FAIL,$REL_RUNNING]" 0 0)
expect "one failed release run -> failed without waiting for the others" "failed" "$(first "$out")"
has_line "failed lists the failed run URL" "failure $R/5" "$out"

out=$(watch 999 "[$REL_FAIL]" 0 0)
expect "gh failing throughout -> unknown, never failed" "unknown" "$(first "$out")"

out=$(watch 2 "[$REL_OK]" 0 1)
expect "flaky gh (TLS timeouts, then ok) is retried to a terminal result" "success" "$(first "$out")"

out=$(watch 0 "[$REL_OK,$REL_FAIL]" 0 0 "Deploy Prod")
expect "workflow filter ignores other release workflows" "success" "$(first "$out")"

exit $FAIL
