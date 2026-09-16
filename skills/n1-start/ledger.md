# Decision Ledger

**Location:** `## Decision Ledger` in overview.md; create then append.

```
| <step> | <category> | <tier> | <tag> | <question> | <chosen> | <alternatives> | <reason> | <rungs_tried> |
```

Steps are ticket through start; categories design/mechanical/quality/scope; tiers A (quality escalation), B, C; tags auto/auto-decided/asked. Question/chosen are one clause, reason nonempty, alternatives comma-separated or —. Rungs are codebase/web/prescribed/telemetry/---: asked lists them, auto uses ---, decide-for-me lists used rungs.

```markdown
## Decision Ledger

| Step | Category | Tier | Tag | Question | Chosen | Alternatives | Reason | Rungs Tried |
|------|----------|------|-----|----------|--------|--------------|--------|-------------|
```

## Rules

Append-only; reason and asked answer required; escape `|` as `/`; one clause/cell; old missing ninth cell is `---`.

## Resolution Ladder

Before a non-unconditional prompt: codebase → web → prescribed/default → telemetry/memory; resolve when found. Otherwise offer Decide for me, search/apply, and record auto-decided.

## Writers


## PR Rendering

Tech-writer renders ledger as `## Decisions` — tier A first, then B, C; `[auto]` before `[asked]` within tier.
