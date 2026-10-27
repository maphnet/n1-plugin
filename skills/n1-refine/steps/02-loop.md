<!-- Purpose: contradiction gate, tiering, question batches, scope widening, readiness verdict (Steps 1-5). -->

## Step 1: Contradiction Gate

```bash
source ~/.n1/preamble.sh
n1_read_signal "$N1_HOME/memory/<ID>/refine/analysis.md" ticket_contradictions
```

Above 0: list the Contradicted claims from `### Ticket Validation`, then ask the user (same choice as `skills/n1-start/steps/analysis.md`):

No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Continue: keep the ticket's direction; record each contradicted claim as an Assumption with its risk
2 — Redirect: end refine without writing anything; edit the ticket, then re-run

## Step 2: Answer From Code First

Collect open points: `### Decision Points` in analysis.md, `### Ambiguities` in refine/ticket.md, and `<!-- n1:unknown -->` markers in investigation.md when present. Resolve before asking:
- **C** — decide by convention; record as an Assumption.
- **B** — decide from the cited evidence; record as a Decision whose Why names the file:line, or as an Assumption when the user may still overturn it.
- **A** — ask in Step 3.

Re-run: Decisions from the existing block stay unless the user changes them; its Assumptions are re-tiered with the rest.

## Step 3: Question Batches

Ask at most 4 questions per message; there is no round cap. Continue until every A-tier point is answered or parked; the user may reply "done" to park all remaining ones. Answers that open new questions join the next batch. Each question, recommendation first:

```
Q<n> <topic>: <why it matters, one line>
1 — <option> (Recommended): <evidence, file:line>
2 — <option>
3 — Park: keep <default> as an Assumption
4 — Decide for me
```

Exactly one `(Recommended)`, with codebase evidence right after it. When the evidence does not differentiate, put "No recommendation. The options are equivalent given the available evidence; select based on team preference." above the options, label none, and Park keeps option 1. **Decide for me:** apply the recommended option; with none, dispatch persona `solution-architect` with "Answer only: <question>. ≤200 words." and apply its answer. Record answered points as Decisions (`Rejected:` lists the options not chosen) and parked points as Assumptions.

## Step 4: Scope Widening

An answer that adds a repository, a deliverable or user-visible behavior outside the ticket's stated scope:
1. Run `<N1_ROOT>/references/duplicate-check.md` § Check on the widened summary, the way `<N1_ROOT>/skills/n1-ticket/steps/02-create.md` does; show any hits; apply no links.
2. Reclassify with `<N1_ROOT>/references/ticket-scope.md`. `SCOPE_TYPE=Story`: ask the user:
   1 — Hand off to n1-story (Recommended): `references/ticket-scope.md` classifies this scope as a Story
   2 — Narrow the scope back to one Task and continue

   Hand-off: follow ticket-scope.md § Handoffs "Story scope in n1-refine"; refine writes no block.

## Step 5: Readiness Verdict

N = A-tier points the user parked. N = 0: `Executable without questions: yes`. Otherwise `Executable without questions: no — N open`, followed by the parked points. Carry the verdict and the draft lists into `03-write.md`.
