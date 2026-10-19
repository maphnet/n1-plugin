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
ev="" wf="" commit=""
while [ $# -gt 0 ]; do
    case "$1" in --event) ev="$2" ;; --workflow) wf="$2" ;; --commit) commit="$2" ;; esac
    shift
done
[ "$commit" = abc123 ] || { echo "[]"; exit 0; }
# $GH_SEQ: call N (counting from the first non-failing call) answers with fixture file $GH_SEQ/N, else the last one.
if [ -n "${GH_SEQ:-}" ]; then
    i=$(( n - ${GH_FAIL_FIRST:-0} )); [ -f "$GH_SEQ/$i" ] || i=$(ls "$GH_SEQ" | wc -l)
    GH_RUNS=$(cat "$GH_SEQ/$i")
fi
jq -c --arg ev "$ev" --arg wf "$wf" \
    '[.[] | select(($ev == "" or .event == $ev) and ($wf == "" or .workflowName == $wf)) | {status, conclusion, url}]' <<<"$GH_RUNS"
EOF
# Fake clock: sleep advances $CLOCK_OFF instead of waiting; date +%s reads real time plus the offset.
printf '#!/usr/bin/env bash\necho $(( $(cat "$CLOCK_OFF" 2>/dev/null || echo 0) + ${1%%.*} )) > "$CLOCK_OFF"\n' > "$T/bin/sleep"
printf '#!/usr/bin/env bash\necho $(( $(/bin/date +%%s) + $(cat "$CLOCK_OFF" 2>/dev/null || echo 0) ))\n' > "$T/bin/date"
chmod +x "$T/bin/gh" "$T/bin/sleep" "$T/bin/date"
export CLOCK_OFF="$T/off"

watch() { # <fail-first> <runs-json> <grace> <max-minutes> [workflow] -> helper stdout
    rm -f "$T/count" "$T/off"
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

out=$(watch 0 "[$REL_OK,$REL_SKIP]" 0 1)
expect "all release runs success/skipped -> success" "success" "$(first "$out")"
has_line "success lists the run URL" "success $R/3" "$out"

out=$(watch 0 "[$REL_FAIL,$REL_RUNNING]" 0 0)
expect "one failed release run -> failed without waiting for the others" "failed" "$(first "$out")"
has_line "failed lists the failed run URL" "failure $R/5" "$out"

out=$(watch 999 "[$REL_FAIL]" 0 0)
expect "gh failing throughout -> unknown, never failed" "unknown" "$(first "$out")"

out=$(watch 2 "[$REL_OK]" 0 5)
expect "flaky gh (TLS timeouts, then ok) is retried to a terminal result" "success" "$(first "$out")"

out=$(watch 0 "[$REL_OK,$REL_FAIL]" 0 1 "Deploy Prod")
expect "workflow filter ignores other release workflows" "success" "$(first "$out")"

seq() { # <grace> <max-minutes> <runs-json>... -> helper stdout; the Nth fixture answers the Nth gh call
    local g="$1" m="$2"; shift 2
    rm -rf "$T/seq" "$T/count" "$T/off"; mkdir "$T/seq"
    local i=0; for j in "$@"; do i=$((i + 1)); printf '%s' "$j" > "$T/seq/$i"; done
    GH_SEQ="$T/seq" GH_RUNS="[]" GH_COUNT="$T/count" PATH="$T/bin:$PATH" \
        bash -c 'source lib/poll.sh; n1_wait_release_runs abc123 "$@"' _ "$g" "$m"
}
NOTIFY_OK='{"event":"release","workflowName":"Notify","status":"completed","conclusion":"success","url":"'$R'/6"}'

out=$(seq 0 5 "[$NOTIFY_OK]" "[$NOTIFY_OK,$REL_RUNNING]" "[$NOTIFY_OK,$REL_OK]")
expect "late-registering deploy run: first all-complete sighting is not success" "success" "$(first "$out")"
has_line "success reflects the late deploy run" "success $R/3" "$out"

out=$(seq 0 1 "[$NOTIFY_OK]" "[$NOTIFY_OK,$REL_RUNNING]")
expect "late deploy run still running at chunk end -> pending" "pending" "$(first "$out")"
has_line "pending lists the late deploy run" "in_progress $R/2" "$out"

out=$(seq 0 0 "[$NOTIFY_OK]")
expect "no room for the confirmation poll before chunk end -> pending, not success" "pending" "$(first "$out")"
has_line "pending lists the runs seen" "success $R/6" "$out"

out=$(seq 0 1 "[$REL_OK]" "[]")
expect "confirmation poll shrank to [] -> not success" "pending" "$(first "$out")"

out=$(seq 0 1 "[$REL_OK]" "")
expect "confirmation poll failed -> not success" "pending" "$(first "$out")"

out=$(seq 1 2 "[$REL_SKIP]")
expect "all skipped, resolved only after grace -> skipped" "skipped" "$(first "$out")"
expect "all skipped before grace end keeps polling" "4" "$(cat "$T/count")"

out=$(seq 0 1 "[$NOTIFY_OK]" "[$NOTIFY_OK,$REL_FAIL]")
expect "late run failing -> failed" "failed" "$(first "$out")"

out=$(watch 0 "[$REL_SKIP]" 0 1)
expect "every release run skipped -> skipped, not none" "skipped" "$(first "$out")"
has_line "skipped lists the run URL" "skipped $R/4" "$out"

out=$(seq 5 1 "[]" "")
expect "stale empty answer then gh errors until chunk end -> unknown, not none" "unknown" "$(first "$out")"

out=$(watch 4 "[]" 2 8)
expect "outage before the first answer does not consume grace -> none" "none" "$(first "$out")"
expect "grace counted from the first gh answer (5 outage calls + 4 grace polls)" "9" "$(cat "$T/count")"

exit $FAIL
