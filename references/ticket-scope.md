# Ticket Scope Routing

Use the confirmed scope to choose ticket structure, independently of the invoked skill and `mechanicalPrompts` mode. Record `SCOPE_TYPE` using this table before choosing a creation path:

| Required repository work | Meaningful decomposition | SCOPE_TYPE |
|--------------------------|--------------------------|------------|
| One repository | No | Task |
| One repository | Yes | Story |
| Multiple repositories | Either | Story |
| Unknown | Unknown | Resolve scope first |

**Repository work** means required implementation or coordinated rollout in that repository. Reading another repository or consuming an existing API does not by itself make scope cross-repository. An unresolved repository count or decomposition decision needs analysis/discovery before classification; a known multi-repository requirement already establishes Story scope.

**Meaningful decomposition** means distinct deliverables that can be scoped and accepted separately, including dependent deliverables. Tests, documentation, and implementation steps needed for one atomic change belong in that ticket's acceptance criteria. Do not invent children to justify the initially selected command. Example: rename one CLI flag and update its tests/help in one repo → Task; implement a service change and update a client in another repo → Story.

Re-evaluate against the latest confirmed scope before approval and after every edit or removal. If required facts remain unknown, resolve them through the collection flow's analysis/discovery before any tracker write. In automatic mode resolve from available evidence; ask for missing facts that cannot be established. In interactive mode clarify scope, rather than offering to retain an inappropriate ticket structure. A confirmed scope change can change the resulting type.

## Handoffs

Carry the confirmed goal, title/description, acceptance criteria, repository requirements, `SCOPE_TYPE`, analysis/discovery results, tracker settings, and any completed duplicate check with `DUP_LINKS`. Reuse confirmations and completed work still valid for the current scope; initialize any missing tracker operations in the destination's tracker gate. Execute the remaining collection steps in order, including analysis/discovery not already completed for that scope. Skip a completed duplicate search only when its scope is unchanged. The destination still runs its creation approval gate for the resulting type.

- **Task scope in n1-story:** say "This is one atomic change in one repository. Creating one standalone Task." Invoke `n1-ticket` with the captured scope and type `Task`, with no parent or child tickets. Continue at Step 3 in `<N1_ROOT>/skills/n1-ticket/steps/01-compose.md`, reusing completed analysis/discovery, then follow `<N1_ROOT>/skills/n1-ticket/steps/02-create.md`. The destination creates exactly one standalone Task; only the destination reports the created ticket and suggests `n1-start`.
- **Story scope in n1-ticket:** say "This scope needs a Story with child tickets." Invoke `n1-story` with the captured scope, continuing at Step 3 in `<N1_ROOT>/skills/n1-story/steps/01-collect.md`, reusing completed analysis/discovery, then follow `<N1_ROOT>/skills/n1-story/steps/02-compose.md`. Derive meaningful child scopes from the confirmed deliverables and repository work.
- **Already in the matching skill:** continue there. Task scope in `n1-ticket` retains its existing Bug detection for defect reports; a normal atomic change is a Task.

End the originating flow after the destination finishes or cancels. It must not resume its own approval, creation, child linking, or queue suggestion. No tracker ticket may be created before the final scope classification selects that path.
