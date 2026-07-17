
**Ensure dependencies (step mode).** Before any code execution, run the
**Ensure Dependencies(`<ID>`)** procedure (see Workspace Isolation in `SKILL.md`).
In full-pipeline mode this is a no-op. In step mode it lazily installs
`worktree.setup` into the worktree on first need (marker-guarded, so it runs at
most once per worktree).

**Execution mode is predetermined:** Do NOT present execution options to the user. Do NOT invoke superpowers:executing-plans. Always use superpowers:subagent-driven-development regardless of what the plan document or writing-plans suggests.

### Signal-Driven Simplicity Gate

Before the normal planning_need routing, check runtime signals for a simple-task bypass:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
TIER=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "tier")
BLAST=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "blast_radius")
FILES_CHANGED=$(n1_read_signal "$N1_HOME/memory/$ID/analysis.md" "files_changed")
```

**If ALL three conditions hold:**
1. `TIER == "simple"`
2. `BLAST == "low"`
3. `FILES_CHANGED < 3` (numeric comparison; treat empty as 999)

**→ Simple signal path:** Spawn a single `developer` agent with context `implementation`. Use `n1_resolve_model developer implementation` to get the model (signal-driven downgrade may apply).

Spawn the developer agent with:
- **Input:** `$N1_HOME/memory/<ID>/brainstorm.md` (or `plan.md` if it exists) — instruct: "Read this file for the full task specification. You are in Direct Implementation mode."
- **Output path:** `$N1_HOME/memory/<ID>/implementation.md` — instruct the developer to write the implementation summary there after all changes are complete.
- **Output format:** pass the implementation.md format template verbatim (from the "implementation.md format" section below).
- **Workspace directives:** same as existing direct path — when `WORKTREE_PATH` is set, pass: "Your working directory is `$WORKTREE_PATH`. All file reads, writes, edits, bash commands, and git operations MUST target files within this directory."
- **Scratch artifact policy:** "Throwaway tests under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (gitignored), never into the repo's test suite. Tests verifying the committed change still go into the repo."
- **Hard stops:** Do NOT call `superpowers:finishing-a-development-branch`. Do NOT push, open PRs, or delete branches.
- **Escalation rules:** pass the Confidence-Based Escalation protocol (section below).

Log the gate decision to overview.md `## Key Decisions`:
- Gate triggered: "Implementation simplicity gate: direct developer spawn (tier=$TIER, blast_radius=$BLAST, files_changed=$FILES_CHANGED)"

**If the developer agent succeeds** (produces `implementation.md`), proceed to signal computation and QA (skip the routing below).

**If the developer agent fails** (exits without producing `implementation.md`), fall through to the normal routing below — the existing planning_need-based dispatch acts as the safety net.

**If ANY condition fails → skip this gate** and proceed to the existing "Read the execution path" block below.

---

**Read the execution path:**

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
PLANNING_NEED=$(n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "planning_need")
```

Route based on `PLANNING_NEED`:
- `direct` → **Direct path** (below)
- `plan` or absent → **Evaluate plan complexity** (below), then route to **Simple plan direct path** or **Plan path**

### Direct path (`planning_need: direct`)

**Spawn agent:** developer

Resolve model for `developer` via `n1_resolve_model` with context `implementation`.

The developer runs in Direct Implementation mode — it reads the brainstorm directly and implements without SDD's task decomposition. This is appropriate because `planning_need: direct` tasks have fully-specified brainstorm output with independent, well-scoped changes.

Spawn the developer agent with:
- **Input:** `$N1_HOME/memory/<ID>/brainstorm.md` — instruct: "Read this brainstorm file for the full task specification. You are in Direct Implementation mode (not Fix Cycle mode)."
- **Output path:** `$N1_HOME/memory/<ID>/implementation.md` — instruct the developer to write the implementation summary there after all changes are complete.
- **Output format:** pass the implementation.md format template verbatim (from the "implementation.md format" section below).
- **Workspace directives:** same as the plan path — when `WORKTREE_PATH` is set, pass: "Your working directory is `$WORKTREE_PATH`. All file reads, writes, edits, bash commands, and git operations MUST target files within this directory."
- **Scratch artifact policy:** "Throwaway tests under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (gitignored), never into the repo's test suite. Tests verifying the committed change still go into the repo."
- **Hard stops:** Do NOT call `superpowers:finishing-a-development-branch`. Do NOT push, open PRs, or delete branches.
- **Escalation rules:** pass the Confidence-Based Escalation protocol (section below).

### Simple plan evaluation (`planning_need: plan`)

When `PLANNING_NEED` is `plan` (or absent), evaluate whether the plan is simple enough to bypass SDD. Read `$N1_HOME/memory/<ID>/plan.md` — if plan.md does not exist, skip evaluation and route directly to **Plan path** below (which already handles missing plan.md by falling back to brainstorm.md). Apply these criteria:

1. **Count tasks** — scan for top-level task headers (`## Task` or `### Task`, following the Superpowers writing-plans format). Count distinct task entries.
2. **If count > 2** — the plan is complex. Route to **Plan path** below.
3. **If count <= 2** — evaluate independence:
   - Check for explicit dependency markers between tasks: "depends on Task 1", "after Task 1 completes", "requires output from", "blocked by", or similar cross-task references.
   - Check for implicit coupling: one task creates a resource (schema, API, file) that the other task consumes or queries.
   - If dependencies exist (explicit or implicit) — the plan is complex. Route to **Plan path** below.
   - If tasks are independent — the plan is simple. Route to **Simple plan direct path** below.

Log the routing decision to overview.md `## Key Decisions`:
- Simple plan: "Implementation: simple plan detected (N task(s), independent) — using Direct Implementation mode with plan.md"
- Complex plan: "Implementation: complex plan detected (N tasks / has dependencies) — using SDD"

### Simple plan direct path

**Spawn agent:** developer

Resolve model for `developer` via `n1_resolve_model` with context `implementation`.

The developer runs in Direct Implementation mode with the plan as input. This is appropriate because the plan contains 1-2 independent tasks that fit within a single agent's context window — SDD's decomposition and multi-agent dispatch would add overhead without value.

Spawn the developer agent with:
- **Input:** `$N1_HOME/memory/<ID>/plan.md` — instruct: "Read this plan file for the full task specification. You are in Direct Implementation mode (not Fix Cycle mode). The plan contains 1-2 tasks — implement them sequentially in the order listed."
- **Output path:** `$N1_HOME/memory/<ID>/implementation.md` — instruct the developer to write the implementation summary there after all changes are complete.
- **Output format:** pass the implementation.md format template verbatim (from the "implementation.md format" section below).
- **Workspace directives:** same as the plan path — when `WORKTREE_PATH` is set, pass: "Your working directory is `$WORKTREE_PATH`. All file reads, writes, edits, bash commands, and git operations MUST target files within this directory."
- **Scratch artifact policy:** "Throwaway tests under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (gitignored), never into the repo's test suite. Tests verifying the committed change still go into the repo."
- **Hard stops:** Do NOT call `superpowers:finishing-a-development-branch`. Do NOT push, open PRs, or delete branches.
- **Escalation rules:** pass the Confidence-Based Escalation protocol (section below).

### Plan path (`planning_need: plan`, complex plans)

**Spawn agent:** implementer

Resolve model for `implementer` and for `developer` (SDD subagent model).

The implementer runs `superpowers:subagent-driven-development` in an isolated subagent context. This is deliberate: the SDD Skill creates a turn boundary on completion, and an in-context invocation intermittently causes the orchestrator to stop and yield to the user instead of continuing to QA. A dispatched subagent absorbs this boundary — when the Agent returns, the orchestrator sees a clean tool-call return and continues. (Same pattern as the planner wrapping `writing-plans`.)

Spawn the implementer agent with:
- **Plan path:** `$N1_HOME/memory/<ID>/plan.md` (or `$N1_HOME/memory/<ID>/brainstorm.md` when no plan.md exists). Instruct: "Read the plan once to enumerate tasks and derive success criteria; when dispatching each SDD task subagent, pass that task's own text + success criteria — do NOT paste the whole plan into every task subagent."
- **Before passing plan content:** If plan.md contains ANY execution-skill directive in its header — whether it names `superpowers:executing-plans`, `superpowers:subagent-driven-development`, or both — IGNORE it. The authoritative execution skill is always superpowers:subagent-driven-development.
- **Define success criteria before spawning.** For each plan task, transform it into a verifiable goal. Example: "Add input validation" → "Write tests for empty, oversized, and malformed input, then make them pass."
- **Developer persona constraints** — SDD's implementer subagents do NOT load `agents/developer.md`, so pass these as role guidance (mirroring the canonical persona — keep the two in sync):
  - **Think Before Coding** — state assumptions explicitly; if uncertain, stop and report rather than guessing.
  - **Simplicity First** — write the minimum code that solves the task; no speculative abstractions, no features beyond what was asked.
  - **Surgical Changes** — touch only what the task requires; don't "improve" adjacent code, comments, or formatting.
  - **Goal-Driven Execution** — define verifiable success criteria first, then loop until they are met.
  - Follow existing patterns; introduce no new architectural patterns or dependencies.
  - Every change has a corresponding test (or verify existing tests cover it); commit each logical change separately (atomic commits).
  - If a change requires architectural decisions, report it as "needs escalation" instead of implementing; do not refactor surrounding code.
  - **Scratch vs. committed test artifacts** — throwaway tests under `$N1_HOME/memory/<ID>/benchmarks/` or `$N1_HOME/memory/<ID>/tests/` (gitignored), never into the repo's test suite. Tests verifying the committed change still go into the repo. When unsure, default to scratch.
- **SDD overrides (IMPORTANT):**
  - **Do NOT call `superpowers:finishing-a-development-branch` under any circumstance.** SDD's flow ends by invoking it — it would present merge/PR/discard options that collide with N1's own QA → Review → PR pipeline. STOP at the last completed task.
  - **Workspace isolation is already satisfied** — N1 set up the working branch (or worktree in step mode). When `WORKTREE_PATH` is set, SDD subagents work in `$WORKTREE_PATH`. In branch mode, they work in the current directory on the feature branch. Treat SDD's `superpowers:using-git-worktrees` prerequisite as ALREADY MET: do NOT create a new worktree or switch branches.
  - Skip the final whole-implementation code review — N1's Review stage (Step 7) handles this.
  - Run in CONTINUOUS mode: do NOT pause between tasks to ask for user approval or feedback.
- If config has a model override for developer, instruct: "Use model `<model>` for ALL implementer subagents." Set `CLAUDE_CODE_SUBAGENT_MODEL` environment variable to `<model>` if possible; fall back to the text instruction if not.
- **Worktree working directory (step mode only, when `WORKTREE_PATH` is set):** Pass verbatim: "Your working directory is `$WORKTREE_PATH`. All file reads, writes, edits, bash commands, and git operations MUST target files within this directory. Do NOT operate on the main checkout. Memory files under `$N1_HOME/memory/<ID>/` are written by the orchestrator and are not affected by this restriction."
- **Output path:** `$N1_HOME/memory/<ID>/implementation.md` — instruct the implementer to write the implementation summary there after all tasks complete (format specified in the "After implementation" section below).
- **Escalation rules:** pass the Confidence-Based Escalation protocol (section below). If a "Low confidence + High blast radius" decision arises, the implementer returns BLOCKED with the decision details.

**After the agent returns:**

If the agent returned **DONE:**
- The implementation summary already lives in `$N1_HOME/memory/<ID>/implementation.md` (written by the implementer).

**Compute and persist implementation signals:**
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/signals.sh"
LINES_CHANGED=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "0")
NEW_FILES=$(git diff --name-status HEAD~1 2>/dev/null | grep -c '^A' || echo "0")
CHANGED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || true)
if echo "$CHANGED_FILES" | grep -qvE '\.(md|txt|json|ya?ml|toml|cfg|ini|conf|env)$'; then
    DIFF_SURFACE="code"
else
    DIFF_SURFACE="config"
fi
n1_write_signals "$N1_HOME/memory/$ID/implementation.md" "diff_surface=$DIFF_SURFACE" "lines_changed=$LINES_CHANGED" "new_files_count=$NEW_FILES"
```

- Update overview: `[x] Implementation`, set `step: implementation`
- Proceed to Step 6 (QA).

If the agent returned **BLOCKED:**
- Present the blocker to the user using the Confidence-Based Escalation format below.
- After the user decides, re-spawn the agent (developer for direct path and simple plan path, implementer for complex plan path) with the decision included. For the complex plan path, SDD resumes from its progress ledger (`/.superpowers/sdd/progress.md`) — completed tasks are not re-dispatched.

### Confidence-Based Escalation

During implementation, evaluate each significant decision:

**High confidence → Full autonomy.** Proceed without asking.

**Low confidence + Low blast radius → Proceed with note.** Make the decision, note it in overview's `## Key Decisions`, continue.

**Low confidence + High blast radius → ESCALATE.** Stop and ask:
```
I'm not confident about this decision and it has high impact:

**Decision:** <what needs to be decided>
**Options:**
A. <option> — <tradeoff>
B. <option> — <tradeoff>
C. <option> — <tradeoff>

**My recommendation:** <option> because <reason>

Which approach?
```

**Always escalate for:** security changes, new architectural patterns, public API contract changes (per `escalation.alwaysAskOn` in config).

**implementation.md format** (pass to the agent — this is the format for the output file):
```markdown
## Implementation Summary

### Completed Tasks
- Task 1: <description> — <result>
- Task 2: <description> — <result>

### Files Changed
- <file path> — <what changed>

### Test Results
<test suite output summary>

### Decisions Made
- <decision>: <choice> (reason: <why>)
```

