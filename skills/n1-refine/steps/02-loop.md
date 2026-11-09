<!-- Purpose: contradiction gate, tiering, question batches, scope classification, readiness verdict (Steps 1-5). -->

## Step 1: Contradiction Gate

```bash
source ~/.n1/preamble.sh
n1_read_signal "$N1_HOME/memory/<ID>/refine/analysis.md" ticket_contradictions
```

If the signal is empty or missing, count the `contradicted` lines in `### Ticket Validation` and use that count.

Above 0: list the Contradicted claims from `### Ticket Validation`, then ask the user (same choice as `skills/n1-start/steps/analysis.md`):

No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Continue: keep the ticket's direction; record each contradicted claim as an Assumption with its risk
2 — Redirect: end refine without writing anything; edit the ticket, then re-run

Every `unable to verify` line (match case-insensitively) in `### Ticket Validation` (any count, no gate): show it to the user as `Unverified: <claim>` and record it as an Assumption whose If-wrong names the claim; no new prompt.

## Step 2: Answer From Code First

Collect open points: `### Decision Points` in analysis.md, `### Ambiguities` in refine/ticket.md, and `<!-- n1:unknown -->` markers in investigation.md when present, except those answered under its `### Clarifications` (a deferred one becomes an Assumption). Resolve before asking:
- **C** — decide by convention; record as an Assumption.
- **B** — decide from the cited evidence; record as a Decision whose Why names the file:line, or as an Assumption when the user may still overturn it.
- **A** — ask in Step 3.

Re-run: Decisions from the existing block stay unless the user changes them; its Assumptions are re-tiered with the rest.

## Step 3: Question Batches

Ask at most 4 questions per message; there is no round cap. Continue until every A-tier point is answered or parked; the user may reply "done" to park all remaining ones. Answers that open new questions join the next batch. Each question, recommendation first:

```
Q<n> <topic>: <why it matters, one line>
1 — <option> (Recommended): <evidence, file:line>
2 — <option>: works when <condition>
3 — Park: keep <default> as an Assumption
4 — Decide for me
```

Exactly one `(Recommended)`, with codebase evidence right after it. Every other option gets one line, `works when <condition>`; format: `<N1_ROOT>/references/question-format.md`. When the evidence does not differentiate, put "No recommendation. The options are equivalent given the available evidence; select based on team preference." above the options, label none, and Park keeps option 1. **Decide for me:** apply the recommended option; with none, dispatch persona `solution-architect` with "Answer only: <question>. ≤200 words." and apply its answer. Record answered points as Decisions (`Rejected:` lists the options not chosen) and parked points as Assumptions.

## Step 4: Scope Classification

Classify with `<N1_ROOT>/references/ticket-scope.md` § Decomposition by ticket type, using `ISSUE_TYPE` and `CHILDREN` (`01-fetch.md` Steps 3-3c) and the latest confirmed scope. Runs for every ticket type, and again after any answer that adds a repository, a deliverable or user-visible behavior outside the ticket's stated scope. For such a widening, first run `<N1_ROOT>/references/duplicate-check.md` § Check on the widened summary, the way `<N1_ROOT>/skills/n1-ticket/steps/02-create.md` does; show any hits; apply no links. Widening never ends refine: the new classification feeds the draft.

Results, carried into `03-write.md`:
- `PROPOSED`: children to create. Epic: Stories. Story, or a Task converting to Story: Sub-tasks. Each has a summary, a description and acceptance criteria as plain bullets. Propose only missing children: drop any child that an entry in `CHILDREN` already covers, so a re-run never re-proposes an existing child.
- `CONVERT`: `Task` (Story with one atomic deliverable and empty `CHILDREN`), `Story` (Task classified `SCOPE_TYPE=Story`), or empty.

`ISSUE_TYPE` other than `epic`, `story` or `task` (bug, sub-task, ...): `PROPOSED` and `CONVERT` stay empty; refine writes the block only. `CHILDREN` non-empty: show it first (key, type, summary) and flag gaps (scope no child covers) and overlaps (two children, or a child and the ticket's Out list, covering the same deliverable); a Story with children is never offered Task conversion, and a Task with children is never offered Story conversion. `CHILDREN=unknown`: `PROPOSED` and `CONVERT` stay empty; say "Existing children unknown; refine proposes no children or conversion this run." The user confirms or edits `PROPOSED` and `CONVERT` like any other point in the Step 3 batches; nothing is written in this step.

`SIBLINGS` (`01-fetch.md` Step 3c) non-empty: show it after `CHILDREN` (key, type, status, summary per sibling) and flag overlaps (a sibling and this ticket covering the same deliverable). This is information for the user and the decision batches only: it has no effect on `PROPOSED` or `CONVERT`. `SIBLINGS` empty or `unknown`: show no sibling list (Step 3c already reported `unknown`).

## Step 5: Readiness Verdict

N = A-tier points the user parked. N = 0: `Executable without questions: yes`. Otherwise `Executable without questions: no — N open`, followed by the parked points. Carry the verdict, the draft lists, `PROPOSED` and `CONVERT` into `03-write.md`.
