# Procedure: Workspace Ownership and Handoff

Read on demand from `procedures/workspace-isolation.md § Workspace Decision`.

## Ask (`ask <path> <branch>`)

Headless (`N1_HEADLESS=1` or `N1_UNATTENDED=ask`): never pick an option. This prompt has no recommended option, so follow `procedures/autonomy-headless.md` for a prompt without a recommended option (blocked move, `## Escalations` line, tracker comment, escalate or pause with category `none`).

Interactive: ask the user once:

"This checkout (`<path>`, branch `<branch>`) does not look like `<ID>`'s workspace. How should `<ID>` proceed?"

No recommendation. The options are equivalent given the available evidence; select based on team preference.

1. Use this checkout for `<ID>` anyway
2. Create a separate workspace for `<ID>`
3. Stop

- **1** → act as `stay <path>` (Adopt Checkout records `workspace_path`, so the question is not asked again).
- **2** → run `source ~/.n1/preamble.sh; n1_workspace_decide "<ID>" --elsewhere <--no-handoff when NO_HANDOFF=true>` and act on its token per the Workspace Decision table.
- **3** → fresh run (`FRESH=1`): `source ~/.n1/preamble.sh; n1_step_end "ticket" 1 skipped '{"skip_reason":"workspace_declined"}'`, then STOP. Resume: STOP.

## Handoff (`handoff-create` | `handoff-launch <path>`)

Intake is already persisted (ticket.md, overview.md, In Progress). Fresh run (`FRESH=1`): record the ticket step first. Resume (`FRESH=0`): leave `step:` untouched (it is past `ticket`) and do not close the ticket step. Then hand off:
```bash
source ~/.n1/preamble.sh
ID="<ID>"; [ "${FRESH:-0}" = 1 ] && n1_write_frontmatter "$N1_HOME/memory/$ID/overview.md" step ticket
n1_orca_handoff "$ID" "<TYPE_OVERRIDE, empty if none>" <create for handoff-create | launch for handoff-launch> "<path; launch only>"
```
- `handoff:ok <name> <handle>` → say "`<ID>` handed off to workspace `<name>` (agent `<handle>`); it continues there." Run `source ~/.n1/preamble.sh; n1_active_run_clear`, and on a fresh run first `n1_step_end "ticket" 1 success '{"handoff":"workspace"}'` (closes the ticket step telemetry and checkbox; the `step: ticket` write above already let the new session resume), then STOP: no further pipeline steps in this session.
- `handoff:failed (<reason>)` → say once "Workspace handoff failed (<reason>); continuing in this session." A partly created workspace is left in place and is found by the next run. `handoff-launch <path>` → act as `reuse <path>`; `handoff-create` → act as `create-local`. Then continue the calling step.
