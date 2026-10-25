#!/usr/bin/env bash
# N1-126: n1_wait_ci_checks uses only valid `gh pr checks --json` fields (bucket) and never reads a gh error as green/red.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
expect() { if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
# Fake gh: rejects fields outside the real list like gh 2.97; otherwise applies --jq to $GH_CHECKS.
cat > "$T/bin/gh" <<'EOG'
#!/usr/bin/env bash
[ "$1 $2" = "pr checks" ] || exit 1
while [ $# -gt 0 ]; do
    case "$1" in --json) fields="$2" ;; --jq) q="$2" ;; esac
    shift
done
for f in ${fields//,/ }; do
    case "$f" in bucket|completedAt|description|event|link|name|startedAt|state|workflow) ;;
        *) echo "Unknown JSON field: \"$f\"" >&2; exit 1 ;; esac
done
jq -r "$q" <<<"$GH_CHECKS"
EOG
chmod +x "$T/bin/gh"

run() { GH_CHECKS="$1" PATH="$T/bin:$PATH" bash -c 'source lib/poll.sh; n1_wait_ci_checks 1 0'; }
b() { printf '[{"name":"a","bucket":"%s"},{"name":"b","bucket":"%s"}]' "$1" "$2"; }

expect "all pass/skipping -> green" green "$(run "$(b pass skipping)")"
expect "one fail -> red" red "$(run "$(b pass fail)")"
expect "one cancel -> red" red "$(run "$(b pass cancel)")"
expect "one pending -> pending" pending "$(run "$(b pass pending)")"
expect "fail beats pending -> red" red "$(run "$(b fail pending)")"
expect "no checks registered ([]) -> pending, never green" pending "$(run '[]')"
expect "gh error -> pending, never green/red" pending "$(PATH="$T/bin:$PATH" GH_CHECKS='[]' bash -c 'source lib/poll.sh; gh() { return 1; }; n1_wait_ci_checks 1 0')"
exit $FAIL
