# Decision Ledger

Shared reference for every step that resolves a decision autonomously (or asks the user under an autonomy gate). The ledger is the after-the-fact review artifact: the human reviews accumulated autonomous decisions at the PR checkpoint instead of being interrupted mid-run.

## Location

`## Decision Ledger` section in `$N1_HOME/memory/<ID>/overview.md`. Create the section (with the table header) on first write; append rows afterwards.

## Entry Format

One markdown table row per decision:

```
| <step> | <category> | <tier> | <tag> | <question> | <chosen> | <alternatives> | <reason> | <rungs_tried> |
```

- **step** — pipeline step name (`ticket`, `brainstorm`, `qa`, `review`, `fix`, `local-testing`, `pr`, `start`)
- **category** — `design` | `mechanical` | `quality` | `scope`
- **tier** — `A` (blocking-grade impact), `B` (significant), `C` (routine). Quality escalations resolved autonomously are always `A`.
- **tag** — `[auto]` (decided autonomously), `[auto-decided]` (clear recommendation, no viable alternative, decided without asking), or `[asked]` (human answered)
- **question** — what was being decided, one clause
- **chosen** — the selected option, one clause
- **alternatives** — rejected options, comma-separated (or `—`)
- **reason** — why, one clause. NEVER empty: every autonomous skip or selection records a reason (the `noTestReason` principle).
- **rungs_tried** -- resolution ladder rungs attempted before asking: `codebase` (Read/Grep/Glob), `web` (WebSearch), `prescribed` (command prescription), `telemetry` (telemetry/memory lookup), `---` (not applicable, e.g. for `[auto]` decisions that did not need a ladder). Comma-separated. Required for `[asked]` rows; `---` for `[auto]` and `[auto-decided]` rows.

Section skeleton written on first entry:

```markdown
## Decision Ledger

| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |
|------|----------|------|-----|----------|--------|--------------|--------|-------------|
```

## Rules

1. **Append-only within a run.** Fix cycles and re-runs never rewrite or delete past rows.
2. **Every writer records a reason.** An entry without a reason is a bug.
3. **`[asked]` entries too.** When an autonomy gate WOULD have auto-decided but tier/margin forced a question, record the human's answer with tag `[asked]` — the PR reviewer sees which decisions had human eyes.
4. **Escape pipes.** Replace any `|` inside cell text with `/` before writing the row.
5. **Keep cells short.** One clause each; details live in the step's own memory file.
6. **Backward compatibility.** Existing rows written before v2.90.0 lack the 9th column. Consumers (tech-writer, n1-telemetry) treat a missing 9th cell as `---`.

## Resolution Ladder

Before issuing any AskUserQuestion (excluding unconditional gates), the asking step MUST attempt resolution in this order:

1. **Codebase search** -- Read/Grep/Glob for evidence. If found, resolve inline and do NOT ask.
2. **Web search** -- WebSearch for docs, best practices, API references. If found, resolve inline and do NOT ask.
3. **Prescribed lookup** -- When the answer is observable on a host the agent cannot reach, note the command and a reasonable default. Resolve inline.
4. **Telemetry/memory** -- Check `$N1_HOME/memory/<ID>/` files and telemetry data for prior decisions on the same question. If found, resolve inline.

Only after all applicable rungs fail should the step escalate to AskUserQuestion. The `rungs_tried` ledger cell records which rungs were attempted (comma-separated).

**"Decide for me" option:** Design and scope category AskUserQuestion calls (not mechanical, not unconditional gates) MUST include a final option: `"Decide for me -- research and apply recommendation"`. When selected:
1. Re-run the resolution ladder with an emphasis on web search (broader queries, multiple sources).
2. Apply the recommendation from the research.
3. Record as `[auto-decided]` with tag `[auto-decided]` and reason starting with `decide-for-me:`.
4. Do NOT ask a follow-up question.

## Writers

| Step | When it writes | `rungs_tried` |
|------|----------------|---------------|
| start (branch/stash preamble) | `mechanicalPrompts: "auto"` resolved a dirty-tree/foreign-branch prompt | `---` (mechanical, no ladder needed) |
| ticket | `mechanicalPrompts: "auto"` auto-created (or auto-skipped) the tracker ticket | `---` (mechanical, no ladder needed) |
| brainstorm | Autonomous brainstormer selected an approach or resolved B/B-auto/C-tier questions; B-auto decisions recorded as `[auto-decided]`; A-tier answers recorded as `[asked]`; `[asked]` rows populate `rungs_tried` per the Resolution Ladder protocol | Comma-separated rungs attempted before any `[asked]` escalation; `---` for `[auto]` and `[auto-decided]` rows |
| qa / review / fix / local-testing | `qualityEscalations: "auto-accept"` accepted a recommendation at loop exhaustion (always tier `A`) | `---` (auto-accept path, no ladder needed) |
| pr | Reviewer skips (security-reviewer gated out) when they were autonomy-influenced | `---` (skip decisions are mechanical) |

## PR Rendering

The tech-writer receives the overview.md path (it already does) and renders the ledger as a `## Decisions` section in the PR body — tier A first, then B, then C; `[auto]` entries before `[asked]` within a tier. See `agents/tech-writer.md`.
