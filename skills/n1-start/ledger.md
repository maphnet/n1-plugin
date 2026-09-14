# Decision Ledger

**Location:** `## Decision Ledger` table in `$N1_HOME/memory/<ID>/overview.md`. Create on first write; append rows.

```
| <step> | <category> | <tier> | <tag> | <question> | <chosen> | <alternatives> | <reason> | <rungs_tried> |
```

- **step**: ticket, brainstorm, qa, review, fix, local-testing, pr, start
- **category**: `design` | `mechanical` | `quality` | `scope`
- **tier**: `A` blocking-grade, `B` significant, `C` routine. Quality escalations always `A`.
- **tag**: `[auto]` autonomous; `[auto-decided]` clear recommendation; `[asked]` human answered
- **question/chosen**: one clause each. **reason**: never empty. **alternatives**: comma-sep or `—`.
- **rungs_tried**: `codebase`, `web`, `prescribed`, `telemetry`, `---`. Required `[asked]`; `---` for `[auto]`; list for "Decide for me" `[auto-decided]`.

```markdown
## Decision Ledger

| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |
|------|----------|------|-----|----------|--------|--------------|--------|-------------|
```

## Rules

1. Append-only. 2. Every entry has a reason. 3. `[asked]`: record human's answer. 4. Escape `|` as `/`. 5. One clause per cell. 6. Pre-v2.90.0 rows: missing 9th cell = `---`.

## Resolution Ladder

Before any user prompt (not unconditional gates): 1→Codebase search, 2→Web search, 3→Prescribed lookup + default, 4→Telemetry/memory check. Found at any rung → resolve inline, no ask. After all fail: escalate with "Decide for me" option. "Decide for me" → web search, apply, record `[auto-decided]`.

## Writers

| Step | When | `rungs_tried` |
|------|------|---------------|
| start | `mechanicalPrompts: "auto"` branch/stash | `---` |
| ticket | auto-created/skipped tracker ticket | `---` |
| brainstorm | SA resolved; A-tier answers `[asked]` | `---` for `[auto]`; list for `[asked]` |
| qa/review/fix/local-testing | `qualityEscalations: "auto-accept"` at exhaustion (always A) | `---` |
| pr | reviewer skips autonomy-influenced | `---` |

## PR Rendering

Tech-writer renders ledger as `## Decisions` — tier A first, then B, C; `[auto]` before `[asked]` within tier.
