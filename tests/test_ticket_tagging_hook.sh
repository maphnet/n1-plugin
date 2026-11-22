#!/usr/bin/env bash
# N1-639: session-start injects the resolved ticket-tagging rule (service, label) on the configured path.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT=$PWD
FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

ctx() { # <config-json> -> additionalContext
    rm -rf "$T/home"; mkdir -p "$T/home" "$T/state"
    printf '%s' "$1" > "$T/home/config.json"
    echo '{"session_id":"s","source":"startup"}' | N1_HOME="$T/home" N1_STATE_DIR="$T/state" N1_HOST_FILE="$T/host" \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash hooks/session-start.sh 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext'
}
has() { # <label> <want-count> <text> <fixed-string>
    local n; n=$(grep -cF -- "$4" <<< "$3" || true); [ "$n" = 0 ] || n=1
    if [ "$n" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}

C=$(ctx '{"ticketTagging":{"enabled":true,"service":"My Service"}}')
has "enabled: line present" 1 "$C" 'TICKET TAGGING:'
has "enabled: title prefix" 1 "$C" 'My Service | <title>'
has "enabled: Service line" 1 "$C" '**Service:** My Service'
has "enabled: label value" 1 "$C" 'adds label my-service'

C=$(ctx '{"ticketTagging":{"enabled":false,"service":"My Service"}}')
has "disabled: no line" 0 "$C" 'TICKET TAGGING:'
C=$(ctx '{"ticketTagging":{"enabled":true,"service":""}}')
has "empty service: no line" 0 "$C" 'TICKET TAGGING:'
C=$(ctx '{"tracker":{"type":"jira"}}')
has "tagging unset: hook still emits context" 1 "$C" 'TICKET CREATION:'
has "tagging unset: no line" 0 "$C" 'TICKET TAGGING:'

C=$(ctx '{"ticketTagging":{"enabled":true,"service":"!!!"}}')
has "empty label: line present" 1 "$C" 'TICKET TAGGING:'
has "empty label: prefix kept" 1 "$C" '!!! | <title>'
has "empty label: no label clause" 0 "$C" 'adds label'

exit $FAIL
