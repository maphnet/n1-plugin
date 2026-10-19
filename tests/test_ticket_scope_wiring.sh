#!/usr/bin/env bash
# N1-84: guard semantic routing at collection and the final pre-write boundary.
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

scope_path = Path('references/ticket-scope.md')
scope = scope_path.read_text() if scope_path.exists() else ''
check('one shared scope rule exists', bool(scope))
check('Task requires one repository and no meaningful decomposition',
      '| One repository | No | Task |' in scope)
check('single-repository decomposition keeps a Story',
      '| One repository | Yes | Story |' in scope)
check('cross-repository work keeps a Story without a local breakdown',
      '| Multiple repositories | Either | Story |' in scope)
check('unknown scope is resolved before creation', '| Unknown | Unknown | Resolve scope first |' in scope)
check('docs and tests do not manufacture child tickets', 'Tests, documentation' in scope)
check('handoffs terminate the originating flow', 'End the originating flow' in scope)
check('Task handoff forbids parent and child creation', 'no parent or child tickets' in scope)

for skill, collect, create in [('n1-story', '01-collect.md', '02-compose.md'),
                               ('n1-ticket', '01-compose.md', '02-create.md')]:
    root = Path('skills') / skill / 'steps'
    collection = (root / collect).read_text()
    creation = (root / create).read_text()
    check(f'{skill} classifies captured scope', 'references/ticket-scope.md' in collection)
    check(f'{skill} rechecks scope before approval and writes',
          0 <= creation.find('references/ticket-scope.md') < creation.find('## Step 7: Approval Gate'))
    check(f'{skill} rechecks edited previews', 'after every edit or removal' in creation)
    check(f'{skill} auto mode cannot preserve the wrong type',
          'auto-proceed with the story' not in collection
          and 'auto-proceed with a single ticket' not in collection)

story = Path('skills/n1-story/steps/02-compose.md').read_text()
check('genuine Story still uses Story creation payload', 'issueTypeName: "Story"' in story)
check('genuine Story still creates linked Jira children', 'parentKey: <STORY_ID>' in story)
check('genuine Story still links YouTrack children', 'link type = `subtask of`' in story)
check('Task route reuses standalone creation', 'skills/n1-ticket/steps/02-create.md' in scope)
check('Story route reuses story collection', 'skills/n1-story/steps/01-collect.md' in scope)
check('Task preview reports the actual type', '**Type:** <Task or Bug>' in Path('skills/n1-ticket/steps/02-create.md').read_text())

# N1-97: one shared rule for free-form creation sites and the Jira param shape.
check('free-form creation section exists', '## Free-form creation' in scope)
check('create-call parameters section exists', '## Create-call parameters' in scope)
check('explicit user-named type wins', 'user explicitly names' in scope and 'wins' in scope)
check('free-form defects become Bugs', 'Bug for a defect report' in scope)
check('free-form unknown scope defaults to Task', 'default to Task' in scope)
check('free-form sections precede handoffs',
      0 <= scope.find('## Free-form creation') < scope.find('## Create-call parameters') < scope.find('## Handoffs'))
check('jc-mcp shape uses issueType without cloudId',
      'starts with `jcm_`' in scope and '`issueType`' in scope and 'No `cloudId`' in scope)
check('Atlassian shape keeps issueTypeName', '`issueTypeName`' in scope)

def line_with(text, needle):
    return next((line for line in text.splitlines() if needle in line), '')

start_ticket = Path('skills/n1-start/steps/ticket.md').read_text()
check('n1-start brain-dump creation cites the scope rule',
      'references/ticket-scope.md' in line_with(start_ticket, '**Tracker ticket creation**'))
inv = Path('skills/n1-start/steps/investigation-deliverable.md').read_text()
check('investigation brain-dump creation cites the scope rule',
      'references/ticket-scope.md' in line_with(inv, 'same mechanics as steps/ticket.md'))
check('investigation follow-up creation cites the scope rule',
      'references/ticket-scope.md' in line_with(inv, 'Call createIssue via tracker MCP'))

if failures:
    raise SystemExit(1)
print('ALL TICKET SCOPE CONTRACTS PASSED')
PY
