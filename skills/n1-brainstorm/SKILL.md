---
name: n1-brainstorm
description: "Use before any creative work in N1 sessions — creating features, building components, or modifying behavior. Explores requirements and produces a design written to the caller-provided output path."
---

# N1 Interactive Brainstorm

## Context

**Inputs (provided by caller):**
- `ticket.md` path — the ticket requirements
- `analysis.md` path — codebase analysis from the solution architect
- Output path — where to write the design (use only the output path provided by the caller)

**GUARDRAIL:** Do NOT Read/Grep/Glob project source files. Step 1 is satisfied by `analysis.md`. Re-spawn the solution-architect persona for missing facts only ("Answer only: \<question\>. ≤200 words.").

## Process

### 1. Ingest Context

Read `ticket.md` and `analysis.md` in full. Identify:
- What the ticket asks for (requirements, acceptance criteria)
- What the analysis found (affected files, patterns, risks, dependencies)
- Whether this is a bug fix, feature, or refactor

### 2. Clarifying Questions

Generate up to 4 clarifying questions that cannot be answered from the provided files. Present ALL questions in one message with a recommended answer for each. Accept "use recommended" as a global reply — apply all recommendations without follow-up. For questions that require facts not in `analysis.md`, dispatch the solution-architect persona. Use "ask the user" (not any tool name) for the interaction.

Only ask questions that materially affect the design. Skip questions answerable from `analysis.md`.

### 3. Approach Generation

Propose 2-3 approaches with tradeoffs. For each describe:
- What it does and how it works
- Advantages and disadvantages
- Which existing patterns it follows or breaks
- Relative effort estimate

Present to the user. Ask which approach to proceed with (or accept the recommended one).

### 4. Design Writing

Write the chosen design to the output path provided by the caller. Do NOT commit the file. Use this structure:

```markdown
# Design: <title>

## Selected Approach
<Which approach was chosen and why>

## Architecture
<High-level architecture>

## Components
<What components are created/modified>

## Data Flow
<How data moves through the system>

## Error Handling
<Error cases and how they're handled>

## Clarifying Questions
<Questions generated and their answers>
```

### 5. Self-Review

Run this 4-point checklist on the written design:

1. **Placeholder scan:** Any "TBD", "TODO", incomplete sections? Fix them.
2. **Internal consistency:** Do sections contradict each other? Does architecture match components?
3. **Scope check:** Is this focused enough for a single implementation plan?
4. **Ambiguity check:** Could any requirement be interpreted two ways? Pick one and make it explicit.

Fix issues inline. No re-review needed.

### 6. Planning-Need Evaluation

Evaluate whether the design is sufficient for direct implementation or whether a formal plan is needed.

**Route `direct` when ALL hold:**
1. Changes are specified — the design names the files and describes what changes in each
2. Changes are independent — no ordering constraints between files
3. No remaining design decisions — the approach is fully resolved
4. No test strategy needed — no new tests or validation approach beyond normal QA

**Route `plan` when ANY hold:**
1. Coordination required — changes interact across files/components, ordering matters
2. Open questions remain — the design flagged uncertainties or decision points
3. New abstractions introduced — new interfaces, modules, or patterns needing specification
4. Non-trivial test/migration strategy — changes need a test plan, migration path, or rollback

**Safety guard (always `plan`):** If `analysis.md` flags security concerns, public API changes, or cross-cutting architectural impact, route to `plan` regardless of design clarity.

**Uncertainty default:** When uncertain, prefer `plan`.

State: "Planning need: [plan/direct] because [one-line reason]."

## Key Principles

- **YAGNI ruthlessly** — remove unnecessary features from all designs
- **Follow existing patterns** — the analysis provides sufficient codebase context
- **Ask only when it matters** — only questions that materially affect the design
- No HARD-GATE, no approval prompts after design is written
