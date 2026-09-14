# Procedure: Output Gates

Defines Gate 1, Gate 2, Gate 3 output formats and inter-gate silence rules.

## Output Gates

Between gates, emit nothing. Do not announce the step being dispatched, the agent being spawned, the model resolved, or the routing decision taken — the pipeline shape is stated once in Gate 1. Memory files carry context between steps; the orchestrator does not.

Four categories may still surface between gates, and nothing else:
1. **Blocking prompts** — any user prompt. You cannot answer a prompt you cannot see.
2. **Warnings and escalations** — anything that changes what "done" will mean, or stops the run.
3. **Fix-loop iterations** — one line per cycle: `<ID> · <loop-name> fix cycle <N>/<MAX>`. Keeps a long run from reading as hung.
4. **The three gates** — defined below.

A length budget removes padding more reliably than any instruction to "be concise." Cut 30% of what's left before emitting a gate — if the meaning survived, that's the version to send.

| Surface | Budget |
|---|---|
| Gate 1 | 12 lines, ~700 characters |
| Gate 2 | 15 lines, ~800 characters |
| Gate 3 | 20 lines, ~1 200 characters |
| Any inter-gate line | 1 line, 20 words |
| Any sentence | 20 words, one idea |

Nothing found → print nothing. No table, no "Nothing needs updating", no summary of having looked. Do NOT list what you wrote down.

### Gate 1 — Task Orientation

Emitted: after analysis completes, on resume, and after compaction recovery.

```
=== <ID> ===
<TITLE>

<CONTEXT_BLOCK>

Tier: <TIER> · Files: ~<FILES_CHANGED> · Blast radius: <BLAST_RADIUS>
Pipeline: <resolved step list, comma-separated>
Workspace: <WORKTREE_PATH> (<BRANCH>)
<TICKET_URL — omit this line entirely if empty>
===
```

**Resume and post-compaction variant** — identical except replace the metadata line with:
```
Tier: <TIER> · Step: <CURRENT_STEP> · Files: ~<FILES_CHANGED>
```
(On resume, where-you-are matters more than blast radius.)

**Folds in (routing decisions surfaced here instead of inline):**
- `Pipeline:` carries the resolved step list, absorbing per-step routing echoes and the investigation-mode pipeline announcement
- `Workspace:` absorbs the worktree-path and IDE-hint lines from the Ensure Worktree procedure
- `<TICKET_URL>` absorbs the ticket ID/URL print from intake

### Gate 2 — Pre-Implementation Brief

Emitted: unconditionally, after plan completes and before implementation starts. Fires on both the plan path and the `planning_need: direct` path.

```
=== <ID> — plan ===
<intent paragraph — 2-3 sentences, product language, no symbol or path names>

Files:
  <path> — add|modify|delete|test
  <path> — add|modify|delete|test

Risk: <one line, the single thing most likely to go wrong>
===
```

**Content sources:**
- Intent paragraph: `overview.md` `## Key Decisions` (recorded by the planner at `steps/plan.md:32`)
- File list: `plan.md` file list section
- Risk line: `analysis.md` signals (blast_radius, complexity_delta)

**`planning_need: direct` branch (no `plan.md`):** Source the intent paragraph from `brainstorm.md`'s chosen approach; emit `Files: (direct path — determined during implementation)`. Do not skip Gate 2 on this branch — a silent implementation start is what this model prevents.

### Gate 3 — Done/Tested Summary

Emitted: at the end of `### 12. FINALIZE MEMORY`, after `n1_active_run_clear`, as the final act of the run.

```
=== <ID> — done ===
Implemented:
  <what a user of this system can now do, or what stopped being broken — one line each, product language>

Tested:
  $ <verbatim command>
  <verbatim result line>

  <STEP>: SKIPPED — <reason>

PR: <url>
===
```

**Three rules:**
1. **Verbatim means verbatim.** Copy the command and result line from `qa.md` / `local-testing.md`. Do not paraphrase, do not summarise to "tests pass".
2. **Skipped steps are printed, never omitted.** Every step not run gets a `SKIPPED — <reason>` line.
3. **`steps/pr.md`'s CHECKPOINT folds here** — the `PR:` line is Gate 3's closing field.

**Content sources:** `implementation.md` `## Implementation Summary`, `qa.md` verdict and Evidence section, `local-testing.md` report, `overview.md` `## Pending` for PR URL.

**Investigation-mode variant:** For investigation tickets, Gate 3 uses the `=== <ID> — done ===` frame and prints the Background, Summary, Metrics, Findings (capped at Gate 3 budget), Recommendations, and Next Steps sections from `investigation.md`. The Findings section points to `$N1_HOME/memory/<ID>/investigation.md` for the full text when it would exceed budget. Content stays (F8) — frame changes.
