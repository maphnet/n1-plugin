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

# Create sites: n1-ticket, n1-story.
for f in skills/n1-ticket/steps/02-create.md skills/n1-story/steps/02-compose.md; do
    check "$f resolves via ticket-tagging" 'ticket-tagging\.md` § Resolve' "$f"
    check "$f labels via ticket-tagging" 'ticket-tagging\.md` § Label after create' "$f"
    lacks "$f has no inline tagging block" 'TAGGING_ENABLED=' "$f"
done
check "n1-story subtasks label after create" 'ticket-tagging\.md` § Label after create with the new subtask ID' skills/n1-story/steps/02-compose.md
check "n1-story adopt gets no tagging or label" 'Adopted tickets get no tagging or label' skills/n1-story/steps/02-compose.md
lacks "n1-story has no vague subtask tagging line" 'same logic as story' skills/n1-story/steps/02-compose.md

# Create sites: n1-start (investigation follow-up, brain-dump), n1-refine children.
for f in skills/n1-start/steps/investigation-deliverable.md skills/n1-start/steps/ticket.md skills/n1-refine/steps/03-write.md; do
    check "$f resolves via ticket-tagging" 'ticket-tagging\.md` § Resolve' "$f"
    check "$f labels via ticket-tagging" '§ Label after create' "$f"
done
lacks "investigation has no vague tagging line" 'Apply ticketTagging rules' skills/n1-start/steps/investigation-deliverable.md

# Create sites run by tail-worker: follow-up filing, n1-finish telemetry follow-up.
F=references/followup-filing.md
for f in "$F" skills/n1-finish/steps/05-telemetry-followup.md; do
    check "$f resolves via ticket-tagging" 'ticket-tagging\.md` § Resolve' "$f"
    check "$f labels via ticket-tagging" 'ticket-tagging\.md` § Label after create' "$f"
done
check "follow-up reconcile accepts plain or tagged summary" 'summary equals the title or the tagged summary' "$F"
check "follow-up markers keep the plain title" 'markers and the duplicate-check `TEXT` keep the plain title' "$F"
check "follow-up label never changes the marker" 'never changes the line.s marker' "$F"
check "follow-up adopted key is never labeled" 'adopted key is never labeled' "$F"
check "follow-up labels before the marker rewrite" 'first apply .*Label after create.* Then rewrite the line as `- \[<KEY> unlinked\]' "$F"
check "missing editTicket warns" 'tracker\.operations\.editTicket is not configured' "$R"
check "collision note makes no guard claim" 'Nothing refuses this collision' "$R"
lacks "no queue-guard claim" 'refuse a tag equal' "$R"
lacks "no silent skip on missing editTicket" 'skip silently' "$R"

# Agent audit: no agent creates tickets directly; tail-worker files through followup-filing.
if grep -qE 'createIssue|create_issue|createJiraIssue|CREATE_ISSUE_OP|CREATE_OP' agents/*.md 2>/dev/null; then
    echo "FAIL: an agent file names a create op directly"; FAIL=1
else
    echo "PASS: no agent file names a create op directly"
fi
check "tail-worker files follow-ups via followup-filing" 'followup-filing\.md` § File' agents/tail-worker.md

# Docs describe the label and point at the rule.
for f in README.md references/architecture.md; do
    check "$f points at ticket-tagging.md" 'references/ticket-tagging\.md' "$f"
    check "$f mentions the service label" 'service label' "$f"
done

exit $FAIL
