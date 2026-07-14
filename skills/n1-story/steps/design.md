# Step 4: Design

## Read Estimation Defaults

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
ESTIMATION_MAPPING=$(cat "${CLAUDE_PLUGIN_ROOT}/defaults/estimation.json")
PROJECT_MAPPING=$(n1_config_val '.estimation.mapping' "$CONFIG_FILE")
MAX_SIZE=$(n1_config_val '.story.taskSizing.maxSize' "$CONFIG_FILE")
MAX_SIZE="${MAX_SIZE:-L}"
WARN_LARGE=$(n1_config_val '.story.taskSizing.warnOnLargeTask' "$CONFIG_FILE")
WARN_LARGE="${WARN_LARGE:-true}"
```

## Spawn Solution Architect

Spawn **solution-architect** with a story-design directive:

- **Agent type:** `n1:solution-architect`
- **Model:** resolve via `n1_resolve_model "solution-architect"`
- **Prompt:**
  - "Synthesize a feature design document from the following inputs:"
  - Paths to Read: `$MEMORY_DIR/ticket.md`, `$MEMORY_DIR/analysis.md`, `$MEMORY_DIR/discovery.md`
  - "Use this exact output structure:"

  ```markdown
  # Design: <Feature Title>

  ## Goal
  One-paragraph statement of what this feature achieves and why.

  ## Success Criteria
  - [ ] Measurable criterion (from ticket.md requirements)

  ## Architecture Overview
  High-level architecture covering all repos. Components, data flow, system boundaries.

  ## Phases

  ### Phase 1: <Name> — <goal>
  **Delivers:** What is usable after this phase completes.
  **Depends on:** Nothing (or prior phase name).

  #### Tasks
  1. **<Task title>** — <1-2 sentence description>
     - Repo: `<repo-name>`
     - Scope: <files/components affected>
     - Acceptance criteria:
       - Given <precondition>, when <action>, then <result>
     - Estimate: <XS|S|M|L|XL> (<time from mapping>)

  ### Phase 2: ...

  ## Cross-Cutting Concerns
  - Migration strategy (if applicable)
  - Feature flags / rollout plan
  - Monitoring / observability
  - Security considerations

  ## Assumptions & Risks
  | Assumption | Source | Risk if wrong |
  |-----------|--------|---------------|
  | ... | ... | ... |

  ## Open Questions
  Items that could not be resolved during discovery (if any).
  ```

  - "Task decomposition rules:"
    - "Each task maps to one `/n1:n1-start` invocation — independently implementable and testable"
    - "Tasks MUST follow INVEST criteria: Independent, Negotiable, Valuable, Estimable, Small, Testable"
    - "Acceptance criteria use Gherkin format: Given/When/Then"
    - "Tasks are ordered within phases by dependency — earlier tasks don't depend on later ones"
    - "Cross-repo tasks specify which repo they target"
    - "Estimates use XS/S/M/L/XL tiers"
  - "Estimation time mapping: `$ESTIMATION_MAPPING`" (include project overrides if present)
  - "Maximum task size before flagging: `$MAX_SIZE`"
  - "Write your output to `$MEMORY_DIR/story-design.md`"

## Task Sizing Guardrail

After the architect returns, read `$MEMORY_DIR/story-design.md` and check each task's estimate.

Define size ordering: XS=1, S=2, M=3, L=4, XL=5. Parse `$MAX_SIZE` to its numeric value.

For each task estimated at or above `$MAX_SIZE` (when `$WARN_LARGE` is `true`):

Present to user: "Task <N> '<title>' is estimated at <size> (<time>). This exceeds the configured maximum of <MAX_SIZE>. (1) Re-decompose this task (2) Keep as-is"

If "Re-decompose": spawn solution-architect again with a targeted prompt to split that specific task into smaller subtasks within the same phase. Update `story-design.md` with the split.

## Update Overview

Update `story-overview.md`:
- Count phases and tasks in `story-design.md`, update frontmatter: `phases_count: <N>`, `tasks_count: <N>`
- Mark Design checkbox complete
- Update `step: design`

**Step result:** `outcome: "pass"`, `next_step: "review"`
