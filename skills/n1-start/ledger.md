# Decision Ledger

Shared reference for every step that resolves a decision autonomously (or asks the user under an autonomy gate). The ledger is the after-the-fact review artifact: the human reviews accumulated autonomous decisions at the PR checkpoint instead of being interrupted mid-run.

## Location

`## Decision Ledger` section in `$N1_HOME/memory/<ID>/overview.md`. Create the section (with the table header) on first write; append rows afterwards.

## Entry Format

One markdown table row per decision:

```
| <step> | <category> | <tier> | <tag> | <question> | <chosen> | <alternatives> | <reason> |
```

- **step** — pipeline step name (`ticket`, `brainstorm`, `qa`, `review`, `fix`, `local-testing`, `pr`, `start`)
- **category** — `design` | `mechanical` | `quality` | `scope`
- **tier** — `A` (blocking-grade impact), `B` (significant), `C` (routine). Quality escalations resolved autonomously are always `A`.
- **tag** — `[auto]` (decided autonomously) or `[asked]` (human answered)
- **question** — what was being decided, one clause
- **chosen** — the selected option, one clause
- **alternatives** — rejected options, comma-separated (or `—`)
- **reason** — why, one clause. NEVER empty: every autonomous skip or selection records a reason (the `noTestReason` principle).

Section skeleton written on first entry:

```markdown
## Decision Ledger

| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason |
|------|----------|------|-----|----------|--------|--------------|--------|
```

## Rules

1. **Append-only within a run.** Fix cycles and re-runs never rewrite or delete past rows.
2. **Every writer records a reason.** An entry without a reason is a bug.
3. **`[asked]` entries too.** When an autonomy gate WOULD have auto-decided but tier/margin forced a question, record the human's answer with tag `[asked]` — the PR reviewer sees which decisions had human eyes.
4. **Escape pipes.** Replace any `|` inside cell text with `/` before writing the row.
5. **Keep cells short.** One clause each; details live in the step's own memory file.

## Writers

| Step | When it writes |
|------|----------------|
| start (branch/stash preamble) | `mechanicalPrompts: "auto"` resolved a dirty-tree/foreign-branch prompt |
| ticket | `mechanicalPrompts: "auto"` auto-created (or auto-skipped) the tracker ticket |
| brainstorm | Autonomous brainstormer selected an approach or resolved B/C-tier questions; A-tier answers recorded as `[asked]` |
| qa / review / fix / local-testing | `qualityEscalations: "auto-accept"` accepted a recommendation at loop exhaustion (always tier `A`) |
| pr | Reviewer skips (Codex inactive, security-reviewer gated out) when they were autonomy-influenced |

## PR Rendering

The tech-writer receives the overview.md path (it already does) and renders the ledger as a `## Decisions` section in the PR body — tier A first, then B, then C; `[auto]` entries before `[asked]` within a tier. See `agents/tech-writer.md`.
