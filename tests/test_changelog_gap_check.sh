#!/usr/bin/env bash
# N1-178: n1-init Operation Gap Check backfills tracker.operations.getChangelog.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
check() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1"; fi
}

G=skills/n1-init/steps/01-prerequisites.md
DETECT=$(grep -o "HAS_GET_CHANGELOG=\$(jq -r '[^']*'" "$G" | head -1 | sed "s/^HAS_GET_CHANGELOG=\$(jq -r '//; s/'\$//")
FILTER=$(grep -o "'\.tracker\.operations\.getChangelog |= [^']*'" "$G" | head -1 | sed "s/^'//; s/'\$//")

# ---- skill text ----
check "gate names the tool" 'mcp__<server>__jcm_getIssueChangelog' "$G"
check "unmappable note present" 'getChangelog not mapped: <reason>; ticket watch stays off.' "$G"

if [ -z "$DETECT" ] || [ -z "$FILTER" ]; then
    fail "detection and patch extractable from skill"
    exit 1
fi

# ---- gap detected ----
got=$(printf '%s' '{"tracker":{"type":"jira","operations":{"readTicket":"x"}}}' | jq -r "$DETECT")
[ -z "$got" ] && pass "gap detected when key absent" || fail "gap detected when key absent: $got"
got=$(printf '%s' '{"tracker":{"operations":{"getChangelog":"jcm_getIssueChangelog"}}}' | jq -r "$DETECT")
[ -n "$got" ] && pass "no gap when key mapped" || fail "no gap when key mapped"

# ---- gap filled / already mapped ----
got=$(printf '%s' '{"tracker":{"other":1,"operations":{"readTicket":"keep"}}}' | jq -c "$FILTER")
[ "$got" = '{"tracker":{"other":1,"operations":{"readTicket":"keep","getChangelog":"jcm_getIssueChangelog"}}}' ] \
    && pass "patch fills absent key, others untouched" || fail "patch fills absent key: $got"
got=$(printf '%s' '{"tracker":{"operations":{"getChangelog":""}}}' | jq -c "$FILTER")
[ "$got" = '{"tracker":{"operations":{"getChangelog":"jcm_getIssueChangelog"}}}' ] \
    && pass "patch fills empty string" || fail "patch fills empty string: $got"
got=$(printf '%s' '{"tracker":{"operations":{"getChangelog":"custom"}}}' | jq -c "$FILTER")
[ "$got" = '{"tracker":{"operations":{"getChangelog":"custom"}}}' ] \
    && pass "patch leaves mapped value alone" || fail "patch leaves mapped value alone: $got"

# ---- AC5: ticket watch sees the op after the patch ----
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT" N1_HOME="$T" ID=T-1
unset N1_RUN_ID N1_SESSION_ID
source "$REPO_ROOT/lib/preamble.sh"
source "$REPO_ROOT/lib/ticket-watch.sh"
printf '%s' '{"tracker":{"mcp":"jc","operations":{}}}' > "$N1_HOME/config.json"
[ -z "$(n1_tw_on "$ID" seed)" ] && pass "watch off before backfill" || fail "watch off before backfill"
jq "$FILTER" "$N1_HOME/config.json" > "$N1_HOME/config.tmp" && mv "$N1_HOME/config.tmp" "$N1_HOME/config.json"
[ "$(n1_tw_on "$ID" seed)" = "$(printf 'jc\tjcm_getIssueChangelog')" ] \
    && pass "n1_tw_on sees getChangelog after backfill" || fail "n1_tw_on sees getChangelog after backfill"

exit "$FAIL"
