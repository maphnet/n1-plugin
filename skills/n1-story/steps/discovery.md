# Step 3: Discovery (Interactive Interview)

## Extract Unknowns

Read `$MEMORY_DIR/analysis.md`. Extract all items tagged with `<!-- confidence: uncertain -->` or `<!-- confidence: unknown -->`.

Also read `$MEMORY_DIR/ticket.md` and extract any items listed under `## Ambiguities` or flagged as unclear.

## Categorize

Group all extracted unknowns into four categories:
- **Product** — what should the feature do? (behavior, edge cases, user flows)
- **Technical** — how should it be built? (architecture choices, library selection, API contracts)
- **Scope** — what's in/out? (phase boundaries, MVP vs full, cross-repo boundaries)
- **Risk** — what could go wrong? (breaking changes, migration concerns, performance)

## Interactive Interview

Present unknowns one-at-a-time to the user, category by category. For each unknown:

1. State the category label (e.g., "[Technical]")
2. State the specific uncertainty clearly
3. Provide context from the analysis — what the architect found and why it's uncertain
4. Offer multiple-choice options where possible, with a recommendation marked as "(Recommended)". Use the `AskUserQuestion` tool when discrete options exist.
5. For open-ended questions (where predefined options don't make sense), ask directly in text.

### Follow-up Questions

If the user's answer reveals a new unknown (e.g., they mention a constraint or dependency not in the analysis), explore it immediately before moving to the next planned question.

### Early Exit

If the user says anything indicating they want to skip remaining questions (e.g., "the rest are fine", "use your judgment", "skip"), record the orchestrator's recommended answer for each remaining item with `Source: Architect recommendation (accepted by user skip)`.

### Completeness Check

After all categories are addressed, ask one final open-ended question:

"Is there anything else about this feature that I should know — constraints, stakeholder concerns, deadlines, or context that didn't come up?"

## Write Discovery Log

Write `$MEMORY_DIR/discovery.md` with all resolved decisions:

```markdown
# Discovery Log

## Product Decisions
### Q: <question text>
**Context:** <what the architect found>
**Decision:** <resolved answer>
**Source:** <User decision | Architect recommendation (accepted by user skip)>
**Confidence:** confident

## Technical Decisions
### Q: <question text>
...

## Scope Decisions
...

## Risk Decisions
...

## Architect Defaults (user skipped)
### Q: <question text>
**Decision:** <architect's recommendation>
**Source:** Architect recommendation (accepted by user skip)
**Confidence:** uncertain → confident
```

If there are no unknowns to resolve (all items were `confident`), write a minimal discovery.md:

```markdown
# Discovery Log

No unknowns identified — all analysis items have confident assessments.
```

Update `story-overview.md`:
- Mark Discovery checkbox complete
- Update `step: discovery`

**Step result:** `outcome: "pass"`, `next_step: "design"`
