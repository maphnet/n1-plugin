---
name: n1-plan
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

**Announce at start:** "I'm using the n1-plan skill to create the implementation plan."

## Scope Check

If the spec covers multiple independent subsystems, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for.

- Design units with clear boundaries and well-defined interfaces.
- Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by layer.
- In existing codebases, follow established patterns.

## Task Right-Sizing

A task is the smallest unit that carries its own test cycle and is worth a fresh reviewer's gate. Fold setup, configuration, scaffolding, and documentation steps into the task whose deliverable needs them; split only where a reviewer could meaningfully reject one task while approving its neighbor.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" — step
- "Run it to make sure it fails" — step
- "Implement the minimal code to make the test pass" — step
- "Run the tests and make sure they pass" — step
- "Commit" — step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

## Global Constraints

[Project-wide requirements — version floors, dependency limits, naming rules,
platform requirements — one line each with exact values. Every task implicitly
includes this section.]

---
```

Write to the output path provided in your dispatch prompt.

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py`
- Test: `tests/exact/path/to/test.py`

**Interfaces:**
- Consumes: [what this task uses from earlier tasks — exact signatures]
- Produces: [what later tasks rely on — exact names and types]

- [ ] **Step 1: Write the failing test**
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Write minimal implementation**
- [ ] **Step 4: Run test to verify it passes**
- [ ] **Step 5: Commit**
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures**:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "handle edge cases" (without code)
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — engineer may read out of order)
- Steps that describe what to do without showing how

## Self-Review

After writing the complete plan, check it against the spec:

1. **Spec coverage:** Can you point to a task for each requirement? List any gaps.
2. **Placeholder scan:** Search for red flags from the "No Placeholders" section. Fix them.
3. **Type consistency:** Do types, method signatures, and names used in later tasks match definitions in earlier tasks?

Fix issues inline. If you find a spec requirement with no task, add the task.
