---
name: n1-refine
description: "Use when a tracker ticket has open decisions, unclear scope or unverified claims to settle with the user before the autonomous pipeline runs: /n1:n1-refine <ID> [--investigate]"
argument-hint: "<ticket-id> [--investigate]"
model: sonnet
effort: medium
---

# N1 Refine

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context. "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Settle a ticket's decisions, scope, acceptance criteria and assumptions with the user, then write them back as one `*Refined by N1*` block. Optional and re-runnable: a re-run replaces the block in place. No branch, no worktree, no status change. All working files live in `$N1_HOME/memory/<ID>/refine/`; the ticket's `overview.md` is never created (n1-start would treat it as a resume).

Run refine before `n1-queue --plan`: a later description edit fails the queue's description checksum closed.

**Announce at start:** "I'm using the n1-refine skill to refine <ID>."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
```

If `N1_HOME` is empty — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Input

`INVESTIGATE=true` when the argument contains `--investigate`; strip the flag, then resolve the ID:

```bash
source ~/.n1/preamble.sh
ARG="<argument without --investigate>"
ID=$(n1_extract_ticket_from_url "$ARG" "$N1_HOME/config.json") || ID="$ARG"
n1_detect_input_type "$ID" "$N1_HOME/config.json"
```

Anything other than `ticket` (brain dump, file, error-tracker URL): say "n1-refine works on an existing ticket. Run `/n1:n1-ticket` first, then `/n1:n1-refine <ID>`." **STOP.**

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Fetch** — tracker gate, author check, fetch, codebase analysis, optional investigation
   Read `<N1_ROOT>/skills/n1-refine/steps/01-fetch.md`

2. **Loop** — contradictions, tiering, question batches, scope widening, readiness verdict
   Read `<N1_ROOT>/skills/n1-refine/steps/02-loop.md`

3. **Write** — draft block, preview, write or comment, handoff
   Read `<N1_ROOT>/skills/n1-refine/steps/03-write.md`
