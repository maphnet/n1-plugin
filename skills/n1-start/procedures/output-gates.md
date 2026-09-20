# Procedure: Output Gates

Between gates: emit nothing. No step announcements, no routing echoes. Only: 1) Blocking prompts. 2) Warnings/escalations. 3) Fix-loop iterations (one line: `<ID> · <loop-name> fix cycle <N>/<MAX>`). 4) The three gates.

Cut 30% of what's left before emitting a gate.

| Surface | Budget |
|---|---|
| Gate 1 | 12 lines, ~700 characters |
| Gate 2 | 15 lines, ~800 characters |
| Gate 3 | 20 lines, ~1 200 characters |
| Any inter-gate line | 1 line, 20 words |

### Gate 1 — Task Orientation

Emitted: after analysis, on resume, post-compaction.

```
=== <ID> ===
<TITLE>

<CONTEXT_BLOCK>

Tier: <TIER> · Files: ~<FILES_CHANGED> · Blast radius: <BLAST_RADIUS>
Pipeline: <resolved step list, comma-separated> — if `SIMPLE_PATH=true`: `analysis → developer → qa → review → pr (simple-path)`
Workspace: <WORKTREE_PATH> (<BRANCH>)
<TICKET_URL — omit if empty>
===
```

Resume/post-compaction: replace metadata with `Tier: <TIER> · Step: <CURRENT_STEP> · Files: ~<FILES_CHANGED>`. Absorbs: routing echoes, investigation-mode announcement, worktree-path lines, ticket URL.

### Gate 2 — Pre-Implementation Brief

Emitted: after plan, before implementation (plan path and `planning_need: direct`).

```
=== <ID> — plan ===
<intent paragraph — 2-3 sentences, product language, no symbol or path names>

Files:
  <path> — add|modify|delete|test

Risk: <one line>
===
```

`planning_need: direct`: source intent from brainstorm.md; emit `Files: (direct path — determined during implementation)`.

### Gate 3 — Done/Tested Summary

Emitted: at end of FINALIZE MEMORY after `n1_active_run_clear`.

```
=== <ID> — done ===
Implemented:
  <what user can now do or what stopped being broken — product language>

Tested:
  $ <verbatim command>
  <verbatim result line>

  <STEP>: SKIPPED — <reason>

PR: <url>
===
```

Rules: 1) Verbatim commands/results from qa.md/local-testing.md. 2) Skipped steps printed. 3) `PR:` is Gate 3's final field.

**Investigation-mode:** use `=== <ID> — done ===`; print Background, Summary, Metrics, Findings (capped), Recommendations, Next Steps from `investigation.md`. Full text pointer if Findings exceed budget.

### Wait Contract

After dispatching any agent persona, the orchestrator MUST idle until the agent tool call returns its result. During the wait:
- Do NOT read ahead to subsequent pipeline steps
- Do NOT re-read the plan, analysis, or skill text
- Do NOT poll for status, check files, or run bash commands
- Do NOT emit progress messages or summaries

The host runtime dispatch mechanism handles completion notification. On timeout (Codex only), re-issue the wait for the same agent — never dispatch a replacement or read ahead.
