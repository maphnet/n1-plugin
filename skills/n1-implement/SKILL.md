---
name: n1-implement
description: Use when executing implementation plans task-by-task with per-task dispatch and review
---

# N1 Implement

Execute an implementation plan by dispatching a developer persona per task, reviewing after each, and running a fix loop when issues are found.

**Announce at start:** "I'm using the n1-implement skill to execute the implementation plan."

## Input

Receive in your dispatch prompt:
- **Plan file path** — the implementation plan (or brainstorm file for direct implementation)
- **Output path** — where to write the implementation summary
- **Worktree path** (optional) — work there if provided
- **Constraints** from the orchestrator (escalation rules, test tier, etc.)

## Process

### 1. Task Enumeration

Read the plan file once. Extract numbered tasks in order. Create a todo per task. Note Global Constraints — they bind every task.

Before dispatching Task 1, scan for conflicts: tasks that contradict each other or the Global Constraints. If found, escalate to your caller before proceeding.

### 2. Per-Task Dispatch Loop

For each task, in sequence:

**a. Compose the task brief** using the Task Brief Template below. Include: where this task fits in the project, the task text, interfaces from prior tasks, your resolution of any ambiguity.

**b. Dispatch the developer persona** with the brief. Never dispatch multiple implementers in parallel (conflicts). Record the commit hash before dispatch (BASE).

**c. Handle the developer report:**
- **DONE:** Proceed to review.
- **DONE_WITH_CONCERNS:** Read concerns; if correctness/scope-related, address before review.
- **NEEDS_CONTEXT:** Provide missing context and re-dispatch.
- **BLOCKED:** Assess: context problem → provide more and re-dispatch; plan defect → escalate to caller.

**d. Review the changes** (generate diff from BASE to HEAD; dispatch task reviewer with Task Review Template). Two verdicts required: spec compliance AND code quality.

**e. Fix loop** (when review finds Critical/Important issues or spec gaps):
- Rounds 1-3: re-dispatch the same developer with the open findings verbatim.
- Rounds 4-5: dispatch a fresh developer with the brief, the findings, and this framing: "A prior developer attempted this task; you own it now."
- Each round: developer fixes, re-runs covering tests, appends fix report. Then dispatch scoped re-review (Re-Review Template) of the fix diff only.
- After round 5 with open findings: adjudicate each — park with ruling if non-load-bearing, STOP and escalate if load-bearing.
- Minor findings: park in the progress ledger, never enter the loop.

**f. Complete the task:** After clean review (or all findings parked at the cap), record completion and move to next task.

### 3. Final Review Gate

After all tasks complete, review the full changeset (diff from merge-base to HEAD) for cross-task consistency. If findings: dispatch ONE fix developer with the complete list, then one scoped re-review. Adjudicate residuals. No second fix wave.

### 4. Write Output

Write the implementation summary to the output path provided.

## Constraints

- No `finishing-a-development-branch`, no push, no PRs, no branch deletion.
- Never fix findings yourself in the controller context — always re-dispatch the developer.
- Never skip the task review. Implementer self-review never replaces the task review.
- Continuous execution: do not pause between tasks unless BLOCKED or all tasks complete.

---

## Task Brief Template

```
Task N of M: [Task Name]

**Context:** [One sentence on where this fits — what the prior task produced, what the next task needs.]

**Requirements:** [Full task text from the plan — exact values verbatim, complete code blocks included.]

**Interfaces from prior tasks:**
- [Function/type/constant name]: [signature and location]

**Constraints:**
- [Global constraints from the plan that bind this task]
- Work in: [worktree path if set]
- Scratch: [N1_HOME/memory/ID/benchmarks/] for throwaway probes

**Report contract:**
Return one of: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
Include: status, commits (short SHAs), one-line test summary, concerns if any.
Write full implementation details to: [report-file path]
```

---

## Task Review Template

```
**Review Task N: [Task Name]**

Verdict required on two dimensions:
1. **Spec compliance** (✅ or ❌): Does the implementation satisfy every requirement in the task text?
2. **Task quality** (Approved / Issues found): YAGNI, no scope creep, tests present and meaningful, no regressions.

**Inputs:** task text (requirements), diff from BASE to HEAD, global constraints.

**Global constraints:** [copy verbatim from plan]

**Finding format:**
- [Critical/Important/Minor]: [finding] — [file:line if applicable]

Critical/Important findings block approval. Minor findings are noted but do not block.
Flag "⚠️ Cannot verify from diff" for requirements in unchanged code or spanning tasks.
```

---

## Re-Review Template

```
**Re-Review Task N, Round R/5**

Open findings from prior review:
[list each finding verbatim]

**Scope:** verify only the fix diff (FIX_BASE to HEAD). For each finding: ADDRESSED or NOT ADDRESSED.
Flag new Critical/Important breakage in the fix diff only. Out-of-scope observations go to deferred list.
```

---

## Implementation Summary Format

Write to the output path:

```markdown
## Implementation Summary

### Completed Tasks
- Task N: <description> — <result>

### Files Changed
- <file> — <what changed>

### Test Results
<test suite output summary>

### Decisions Made
- <decision>: <choice> (reason: <why>)
```
