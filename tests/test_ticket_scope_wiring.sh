#!/usr/bin/env bash
# N1-84: guard semantic routing at collection and the final pre-write boundary.
# N1-297: n1-ticket files Task, Bug, Story or Epic; multi-repository scope is an Epic.
# Behavioral scenario evidence is recorded separately: these are wiring contracts.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from pathlib import Path

failures = []

def check(label, condition):
    print(f"{'PASS' if condition else 'FAIL'}: {label}")
    if not condition:
        failures.append(label)

def line_with(text, needle):
    return next((line for line in text.splitlines() if needle in line), '')

def section(text, start, end):
    i = text.find(start)
    j = text.find(end, i + 1) if i >= 0 else -1
    return text[i:j] if 0 <= i < j else ''

scope_path = Path('references/ticket-scope.md')
scope = scope_path.read_text() if scope_path.exists() else ''
check('one shared scope rule exists', bool(scope))
check('Task requires one repository and no meaningful decomposition',
      '| One repository | No | Task |' in scope)
check('single-repository decomposition is a Story',
      '| One repository | Yes | Story |' in scope)
check('cross-repository work is an Epic',
      '| Multiple repositories | Either | Epic |' in scope)
check('cross-repository work is no longer a Story',
      '| Multiple repositories | Either | Story |' not in scope)
check('a known multi-repository requirement establishes Epic scope',
      'establishes Epic scope' in scope)
check('unknown scope is resolved before creation', '| Unknown | Unknown | Resolve scope first |' in scope)
check('docs and tests do not manufacture child tickets', 'Tests, documentation' in scope)
check('handoffs between creation skills are gone',
      '## Handoffs' not in scope and 'End the originating flow' not in scope)

collection = Path('skills/n1-ticket/steps/01-compose.md').read_text()
creation = Path('skills/n1-ticket/steps/02-create.md').read_text()
check('n1-ticket classifies captured scope', 'references/ticket-scope.md' in collection)
check('n1-ticket rechecks scope before approval and writes',
      0 <= creation.find('references/ticket-scope.md') < creation.find('## Step 7: Approval Gate'))
check('n1-ticket auto mode cannot preserve the wrong type',
      'auto-proceed with the story' not in collection
      and 'auto-proceed with a single ticket' not in collection)
check('Task gate reports the actual type', 'Show the resulting **Type: Task** (or **Bug**' in creation)

# N1-97: one shared rule for free-form creation sites and the Jira param shape.
check('free-form creation section exists', '## Free-form creation' in scope)
check('create-call parameters section exists', '## Create-call parameters' in scope)
check('explicit user-named type wins', 'user explicitly names' in scope and 'wins' in scope)
check('free-form defects become Bugs', 'Bug for a defect report' in scope)
check('free-form unknown scope defaults to Task', 'default to Task' in scope)
check('free-form type picks Epic for several repositories', 'Epic for several repositories' in scope)
check('free-form Story or Epic needs the user to name or confirm it',
      'only when the user names it or confirms it' in scope)
check('free-form sections precede decomposition',
      0 <= scope.find('## Free-form creation') < scope.find('## Create-call parameters')
      < scope.find('## Decomposition by ticket type'))
check('jc-mcp shape uses issueType without cloudId',
      'starts with `jcm_`' in scope and '`issueType`' in scope and 'No `cloudId`' in scope)
check('Atlassian shape keeps issueTypeName', '`issueTypeName`' in scope)
check('YouTrack shape names a type mechanism', 'enum field named "Type"' in scope)
create_params = section(scope, '## Create-call parameters', '## Decomposition by ticket type')
check('create-call parameters name Story and Epic values',
      'issueType: "Epic"' in create_params and 'issueTypeName: "Epic"' in create_params
      and '"Story"' in create_params)
check('a Story or Epic parent never takes parentKey', 'never pass `parentKey` for it' in create_params)
check('YouTrack missing type adds a description note', 'type not available in project' in create_params)
check('n1-ticket Step 6 does not hard-code issueTypeName Bug', 'issueTypeName: "Bug"' not in creation)

start_ticket = Path('skills/n1-start/steps/ticket.md').read_text()
check('n1-start brain-dump creation cites the scope rule',
      'references/ticket-scope.md' in line_with(start_ticket, '**Tracker ticket creation**'))
inv = Path('skills/n1-start/steps/investigation-deliverable.md').read_text()
check('investigation follow-up creation cites the scope rule',
      'references/ticket-scope.md' in line_with(inv, 'Call createIssue via tracker MCP'))

# Every skill file that creates tracker tickets must cite the shared rule.
CREATE_MARKERS = ('createIssue', 'CREATE_ISSUE_OP', 'create_issue', 'createJiraIssue', 'jcm_createIssue')
# n1-init maps op names into config; it never creates a ticket. Do not add call sites here.
NOT_CALL_SITES = {'skills/n1-init/steps/03-tracker.md'}
for path in sorted(Path('skills').rglob('*.md')):
    rel = path.as_posix()
    text = path.read_text()
    if rel in NOT_CALL_SITES or not any(m in text for m in CREATE_MARKERS):
        continue
    check(f'{rel} cites the shared scope rule', 'references/ticket-scope.md' in text)

followup = Path('skills/n1-finish/steps/05-telemetry-followup.md').read_text()
check('telemetry follow-up drops the ad hoc issuetype shape', '"issuetype"' not in followup)
check('telemetry follow-up stays a Task', 'type Task' in followup)

ticket_create = section(creation, '**Create the ticket:**', '**Assign to creator**')
check('n1-ticket has a jc-mcp create branch',
      'starts with `jcm_`' in ticket_create and '`issueType`' in ticket_create)
check('n1-ticket keeps the Atlassian create branch', '`issueTypeName`' in ticket_create)

hook = Path('hooks/session-start.sh').read_text()
hb_start = hook.find('HOST_BLOCK="')
hb_end = hook.find('CONFIG_FILE=$(n1_config_file)', hb_start)
host_block = hook[hb_start:hb_end] if 0 <= hb_start < hb_end else ''
check('HOST ROUTING routes free-form creation to the scope rule',
      'TICKET CREATION:' in host_block and 'references/ticket-scope.md' in host_block)
check('HOST ROUTING honors a user-named type', 'a user-named type wins' in host_block)

if failures:
    raise SystemExit(1)
print('ALL TICKET SCOPE CONTRACTS PASSED')
PY
