# Ticket Scope Routing

Use the confirmed scope to choose the ticket type, independently of the invoked skill. Record `SCOPE_TYPE` using this table before choosing a type:

| Required repository work | Meaningful decomposition | SCOPE_TYPE |
|--------------------------|--------------------------|------------|
| One repository | No | Task |
| One repository | Yes | Story |
| Multiple repositories | Either | Epic |
| Unknown | Unknown | Resolve scope first |

**Repository work** means required implementation or coordinated rollout in that repository. Reading another repository or consuming an existing API does not by itself make scope cross-repository. An unresolved repository count or decomposition decision needs analysis/discovery before classification; a known multi-repository requirement already establishes Epic scope.

**Meaningful decomposition** means distinct deliverables that can be scoped and accepted separately, including dependent deliverables. Tests, documentation, and implementation steps needed for one atomic change belong in that ticket's acceptance criteria. Do not invent children to justify a larger type. Example: rename one CLI flag and update its tests/help in one repo → Task; split one repository's feature into separately accepted deliverables → Story; implement a service change and update a client in another repo → Epic.

Re-evaluate against the latest confirmed scope before creation. If required facts remain unknown, resolve them through the collection flow's analysis/discovery before any tracker write. Resolve from available evidence rather than retaining an inappropriate ticket type. A confirmed scope change can change the resulting type. Creating a Story or Epic never creates its children; `n1-refine` proposes them per § Decomposition by ticket type.

## Free-form creation

Applies to tracker create calls outside `n1-ticket` that choose a type: n1-start brain-dump creation, investigation follow-ups, and n1-run or ad hoc requests. (n1-finish telemetry follow-ups are always Task and use only § Create-call parameters.) Pick the type:

- An issue type the user explicitly names (e.g. "create a Story") wins over every rule below.
- Bug for a defect report.
- Otherwise use the `SCOPE_TYPE` table above: Task for atomic single-repository work; Story for one repository with meaningful decomposition; Epic for several repositories.
- Unknown scope: default to Task (overrides the table's Unknown row for free-form sites), note the assumption in the description, and do not block creation. These sites have no collection flow to resolve scope.

Free-form sites create a Story or Epic only when the user names it or confirms it; otherwise create a Task and note the larger scope in the description.

Pass the type using the parameter names in § Create-call parameters.

## Create-call parameters

The type argument depends on the configured create op (`CREATE_ISSUE_OP=$(n1_config_val '.tracker.operations.createIssue')`):

- **Jira, op starts with `jcm_`** (jc-mcp): `projectKey`, `issueType`, `summary`, `description` (plus `parentKey` for a child). No `cloudId`.
- **Jira, any other op** (Atlassian Rovo `createJiraIssue`): `cloudId` (`n1_config_val '.tracker.cloudId'`, else the `id` from `getAccessibleAtlassianResources`), `projectKey`, `issueTypeName`, `summary`, `description`.
- **YouTrack:** `project`, `summary`, `description`, using the tool's own argument names. For a non-default type, set the project's enum field named "Type" to it in the create call (verify the value via `getProjectFields` when configured, as in `<N1_ROOT>/skills/n1-ticket/steps/02-create.md` Step 6); if the value is unavailable or unverifiable, create with the default type.

The type value is `"Task"`, `"Bug"`, `"Story"` or `"Epic"` (e.g. jc-mcp `issueType: "Epic"`, Rovo `issueTypeName: "Epic"`). A Story or Epic created as a parent needs only the fields above; never pass `parentKey` for it. On YouTrack, when the "Type" value is unavailable, add to the description: "**Note:** <Type> type not available in project — created as default type."

Every create call also applies `<N1_ROOT>/references/ticket-tagging.md` § Resolve before the call and § Label after create once the new key is known.

## Decomposition by ticket type

n1-refine applies this mapping to an existing ticket: `issue_type` from intake, existing children listed from the tracker. Classify the latest confirmed scope with the `SCOPE_TYPE` table above first; the ticket type then selects the action offered. Nothing is converted or created until the user picks it.

| Ticket type | Classification | Action offered |
|---|---|---|
| Epic | always decomposes | propose missing Stories (summary, description, acceptance criteria) |
| Story | meaningful decomposition | propose missing Sub-tasks (summary, description, acceptance criteria) |
| Story, no children | one atomic deliverable | offer converting to Task; no children |
| Story with children | already decomposed | list the children, flag gaps and overlaps, propose only missing ones; never convert |
| Task | `SCOPE_TYPE=Story` | offer converting to Story, then propose Sub-tasks |
| Task | `SCOPE_TYPE=Epic` | refine the block only; note the multi-repository scope and that no Epic conversion is offered |
| Task | `SCOPE_TYPE=Task` | refine the block only |

A Story that classifies as `SCOPE_TYPE=Epic` follows its Story rows above. Any other type (Bug and the like) is handled as a Task with `SCOPE_TYPE=Task`: refine the block only.
