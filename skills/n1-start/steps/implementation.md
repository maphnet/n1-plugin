
**Ensure dependencies (step mode).** Before any code execution, run the
**Ensure Dependencies(`<ID>`)** procedure (see Workspace Isolation in `SKILL.md`).
In full-pipeline mode this is a no-op. In step mode it lazily installs
`worktree.setup` into the worktree on first need (marker-guarded, so it runs at
most once per worktree).

**Execution mode is predetermined:** Do NOT present execution options to the user. Do NOT invoke superpowers:executing-plans. Always use superpowers:subagent-driven-development regardless of what the plan document or writing-plans suggests.

**Spawn agent:** implementer

Resolve model for `implementer` and for `developer` (SDD subagent model).

The implementer runs `superpowers:subagent-driven-development` in an isolated subagent context. This is deliberate: the SDD Skill creates a turn boundary on completion, and an in-context invocation intermittently causes the orchestrator to stop and yield to the user instead of continuing to QA. A dispatched subagent absorbs this boundary — when the Agent returns, the orchestrator sees a clean tool-call return and continues. (Same pattern as the planner wrapping `writing-plans`.)

Spawn the implementer agent with:
- **Plan path:** `$N1_HOME/memory/<ID>/plan.md` (or `$N1_HOME/memory/<ID>/brainstorm.md` for simple tasks). Instruct: "Read the plan once to enumerate tasks and derive success criteria; when dispatching each SDD task subagent, pass that task's own text + success criteria — do NOT paste the whole plan into every task subagent."
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

**After the implementer agent returns:**

If the agent returned **DONE:**
- The implementation summary already lives in `$N1_HOME/memory/<ID>/implementation.md` (written by the implementer).
- Update overview: `[x] Implementation`, set `step: implementation`
- Proceed to Step 6 (QA).

If the agent returned **BLOCKED:**
- Present the blocker to the user using the Confidence-Based Escalation format below.
- After the user decides, re-spawn the implementer with the decision included. SDD resumes from its progress ledger (`/.superpowers/sdd/progress.md`) — completed tasks are not re-dispatched.

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

**implementation.md format** (pass to implementer — this is the format for the output file):
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

