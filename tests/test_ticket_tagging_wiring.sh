#!/usr/bin/env bash
# N1-540: one shared ticket-tagging rule (prefix, Service line, service label); every create site points at it.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R=references/ticket-tagging.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}

check "reference has § Resolve" '^## § Resolve$' "$R"
check "reference has § Label after create" '^## § Label after create$' "$R"
check "summary prefix rule" '`<TAGGING_SERVICE> [|] <title>`' "$R"
check "no double prefix" 'already starts with `<TAGGING_SERVICE> [|]`' "$R"
check "Service line" '\*\*Service:\*\* <TAGGING_SERVICE>' "$R"
check "no label when tagging disabled" '\[ "\$TAGGING_ENABLED" = true \] [|][|] TAGGING_LABEL=' "$R"
check "label via update add op" '"labels":\[\{"add":"<TAGGING_LABEL>"\}\]' "$R"
check "never fields.labels" 'Never pass labels under `fields`' "$R"
check "jc-mcp only" 'starts with `jcm_`' "$R"
check "ok:false is a failure" '`ok:false`' "$R"
check "label failure warns" 'Warning: Could not label <KEY> with <TAGGING_LABEL>' "$R"
check "label failure never blocks" 'No retry, no rollback, never block' "$R"
check "YouTrack explicit skip" 'Service label skipped: YouTrack has no label operation' "$R"
check "creation only, adopted never labeled" 'adopted ticket.*never re-tagged or labeled' "$R"
check "version-server jc-mcp creates are labeled" 'mcp__<VERSION_MCP>__jcm_editIssue' "$R"
check "Rovo own-op creates get no label" 'created through the tracker.s own op.*no label' "$R"
check "ticket-scope points at the reference" 'ticket-tagging\.md` § Resolve' references/ticket-scope.md
check "ticket-scope points at label step" '§ Label after create' references/ticket-scope.md

# Sanitizer: evaluate the exact TAGGING_LABEL line from the reference.
expr=$(sed -n 's/^TAGGING_LABEL=//p' "$R")
for pair in 'My Service|my-service' '  A  B |a-b' '!!!|' 'Svc_1|svc_1' 'Tailnet-ACL|tailnet-acl'; do
    TAGGING_SERVICE=${pair%%|*}; want=${pair#*|}; got=
    [ -n "$expr" ] && eval "got=$expr"
    if [ -n "$expr" ] && [ "$got" = "$want" ]; then
        echo "PASS: label '$TAGGING_SERVICE' -> '$want'"
    else
        echo "FAIL: label '$TAGGING_SERVICE' -> '$got' (want '$want')"; FAIL=1
    fi
done

exit $FAIL
