---
name: n1-refine
description: "Use when a tracker ticket has open decisions, unclear scope or unverified claims to settle with the user before the autonomous pipeline runs: /n1:n1-refine <ID>... [--investigate]"
argument-hint: "<ticket-id>... [--investigate]"
model: sonnet
effort: medium
---

# N1 Refine

**Host vocabulary:** "ask the user" / "user prompt" means the host's question mechanism from the HOST ROUTING block in session context. "Dispatch persona `<name>`" and "invoke skill `<x>`" likewise follow HOST ROUTING.

Settle a ticket's decisions, scope, acceptance criteria and assumptions with the user, then write them back as one `*Refined by N1*` block. Decomposes by ticket type (`references/ticket-scope.md` § Decomposition by ticket type): it creates child tickets (Stories under an Epic, Sub-tasks under a Story) only for actions the user confirmed in `02-loop.md` Step 4, right after the block is written; type conversions and adopt candidates are listed in the handoff for the user, never run. Optional and re-runnable: a re-run replaces the block in place and proposes only missing children. No branch, no worktree, no status change. All working files live in `$N1_HOME/memory/<ID>/refine/`; the ticket's `overview.md` is never created (n1-start would treat it as a resume).

Run refine before `n1-queue --plan`: in a queue child, a refined block posted as a comment after the plan is ignored. Refined Decisions never pre-authorize stop-list (security, architecture, public-api) escalations.

**Announce at start:** "I'm using the n1-refine skill to refine <ID>."

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] && echo "N1_HOME=$N1_HOME" || echo N1_NOT_CONFIGURED
```

If the output shows `N1_NOT_CONFIGURED` — N1 is not configured. Tell the user: "N1 is not configured for this project. Run `/n1:n1-init` to set it up." **STOP.**

## Input

`INVESTIGATE=true` when the argument contains `--investigate` (with several tickets it applies to each); strip the flag. The argument holds one or more ticket IDs or tracker URLs, separated by spaces or commas; resolve each, drop duplicates (first kept):

```bash
source ~/.n1/preamble.sh
set -f
IDS=""
for A in $(printf '%s' '<argument without --investigate>' | tr ',' ' '); do
  K=$(n1_extract_ticket_from_url "$A" "$N1_HOME/config.json") || K="$A"
  [ "$(n1_detect_input_type "$K" "$N1_HOME/config.json")" = ticket ] || { echo "ignored:$A"; continue; }
  case " $IDS " in *" $K "*) ;; *) IDS="$IDS $K";; esac
done
echo "IDS=$IDS"
```

`IDS` empty (brain dump, file, error-tracker URL): say "n1-refine works on an existing ticket. Run `/n1:n1-ticket` first, then `/n1:n1-refine <ID>`." **STOP.** Otherwise say "<input>: ignored (not a ticket)" for each `ignored:` line.

One ID: that ID is `<ID>`; follow the Steps below.

Two or more IDs (list mode): read `<N1_ROOT>/skills/n1-refine/steps/00-list.md` and follow it instead; it orders the tickets and runs the Steps below once per ticket.

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Fetch** — tracker gate, fetch, existing children, codebase analysis, optional investigation
   Read `<N1_ROOT>/skills/n1-refine/steps/01-fetch.md`

2. **Loop** — contradictions, tiering, question batches, scope classification, readiness verdict
   Read `<N1_ROOT>/skills/n1-refine/steps/02-loop.md`

3. **Write** — draft block, show it with actions, write or comment, then create confirmed children, handoff
   Read `<N1_ROOT>/skills/n1-refine/steps/03-write.md`
