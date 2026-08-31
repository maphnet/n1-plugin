---
description: When presenting options, mark at most one (Recommended) with factual, tier-appropriate evidence
topic: process
applies_to: [*]
enforcement: gate
---

## Recommended-Option Rule

When presenting two or more options for any decision, apply the following:

### Tier Classification

Classify the decision before selecting evidence:

- **Tier 1 — Design decision:** affects architecture, public API shape, data model, cross-service boundaries, or security model. These decisions require websearch evidence (benchmarks, official docs, community adoption data, or published research) to justify a recommendation.
- **Tier 2 — Tactical decision:** affects implementation detail within already-decided boundaries (variable naming, loop style, library method choice, test structure). These decisions require codebase evidence (existing patterns, project conventions, or prior art within the repository) to justify a recommendation.

When a decision spans both tiers, treat it as Tier 1.

### Marking a Recommendation

Apply exactly one `(Recommended)` label to the option that the evidence most clearly supports.

State the rationale immediately after the label using only evidence gathered for the tier:

- Tier 1 rationale: cite the source (URL, doc name, or benchmark), state the measured or documented advantage, and tie it to the project context.
- Tier 2 rationale: cite the file or pattern in the codebase, state what it establishes, and explain how this option aligns with it.

Keep rationale factual. Remove words such as "I prefer," "I think," or "in my experience." Every claim must be traceable to a source — external for Tier 1, internal for Tier 2.

### When No Option Is Clearly Superior

When the evidence does not differentiate the options, write the following sentence verbatim before the option list:

> No recommendation. The options are equivalent given the available evidence; select based on team preference.

Do not add a `(Recommended)` label in this case.

### Constraint Summary

- At most one `(Recommended)` label per option-select.
- Tier 1 label requires external, verifiable evidence.
- Tier 2 label requires internal, codebase-traceable evidence.
- When evidence is absent or inconclusive, state "No recommendation" explicitly.
