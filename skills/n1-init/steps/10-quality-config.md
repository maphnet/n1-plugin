<!-- Purpose: Configure test coverage tier, autonomy mode, review, CI checks, telemetry, analysis cache, and plan review. -->

## Test Coverage Configuration

Ask what level of test work the QA agent should do. **Default is maintain** — fix and update existing tests, no new test creation.

```
Test coverage tier controls how much test work the QA agent does:
  maintain — Fix broken tests, update tests for changed functionality. No new tests. (default)
  minimal  — Acceptance-criteria-only behavioral tests (1-3 per feature)
  standard — Behavioral tests + edge cases + error paths (capped)

Select test coverage tier:
1 — maintain (default)
2 — minimal
3 — standard
```

**If 1 (maintain) or default:**
```json
{
  "testCoverage": {
    "tier": "maintain"
  }
}
```

**If 2 (minimal):**
```json
{
  "testCoverage": {
    "tier": "minimal"
  }
}
```

**If 3 (standard):**
```json
{
  "testCoverage": {
    "tier": "standard"
  }
}
```

### On reconfiguration (n1-init re-run):

If `testCoverage` already exists in the current config, show current state and offer:
```
Current test coverage tier: <current value>
1 — Keep current
2 — maintain
3 — minimal
4 — standard
```
- **1** → leave unchanged.
- **2** → set `tier: "maintain"`.
- **3** → set `tier: "minimal"`.
- **4** → set `tier: "standard"`.

If `testCoverage` is absent from the current config, run the fresh-setup flow above.

## Autonomy Configuration

Ask:

```
How autonomous should pipeline runs be?

1 — Hands-off (recommended): mechanical prompts auto-resolve with safe defaults; brainstorm
    runs autonomously; acceptance gate auto-confirms; quality-gate exhaustion auto-accepts.
    Every autonomous decision is logged to a Decision Ledger and rendered in the PR body for review.
2 — Interactive: the pipeline asks at every decision point.
```

- **1 (Hands-off)** → write:
  ```json
  "autonomy": { "mode": "hands-off" }
  ```

- **2 (Interactive)** → write:
  ```json
  "autonomy": { "mode": "interactive" }
  ```

Neither option writes individual sub-keys (`brainstorm`, `mechanicalPrompts`, etc.) — those are code defaults derived from `autonomy.mode` at runtime.

Note in the summary output: security, architecture, and public-API escalations always block regardless of this setting, and releases are always manual.

### On reconfiguration (n1-init re-run):

If `autonomy` already exists in the current config:
- If it contains only `"mode"`: show current value and re-ask (two options as above).
- If it contains legacy sub-keys (no `"mode"` key): show a migration note —
  `"Your config uses legacy autonomy keys. Reconfiguring will write the new single-key format."` — then re-ask.

## Review Configuration

Use `minCleanPasses: 1` by default. **Do NOT ask** the user about this unless they explicitly requested review customization when invoking n1-init.

```json
{
  "review": {
    "minCleanPasses": 1
  }
}
```

## CI Checks Configuration

Use defaults. **Do NOT ask** the user about this unless they explicitly requested CI customization when invoking n1-init.

- `enabled: true` — CI watch runs automatically after PR creation in n1-start
- `maxFixAttempts: 3` — developer agent gets 3 cycles to fix CI failures before escalating to user
- `confidenceThreshold: 0.7` — for checks that don't match any known category, developer agent must exceed this confidence to auto-fix

```json
{
  "ciChecks": {
    "enabled": true,
    "maxFixAttempts": 3,
    "confidenceThreshold": 0.7
  }
}
```

Categories use built-in defaults (lint, typecheck, test, build, security, infra — all `auto-fix`). Teams can override by adding a `categories` block after running n1-init.

## Telemetry Configuration

Ask whether N1 should collect local telemetry for pipeline efficiency analysis. **Default is No.**

```
Enable telemetry?
Collects per-step timing, agent performance, and token usage into per-ticket telemetry directories for offline analysis.
Data stays local — no external transmission.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "telemetry": {
    "enabled": false
  }
}
```

**If 1 (Yes):**
```json
{
  "telemetry": {
    "enabled": true
  }
}
```

### On reconfiguration (n1-init re-run):

If `telemetry` already exists in the current config, show current state and offer:
```
Current telemetry:
  enabled → <true/false>

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`.
- **3** → set `enabled: false`.

If `telemetry` is absent from the current config, run the fresh-setup flow above.

## Analysis Cache Configuration

Ask whether N1 should cache project-level analysis snapshots to speed up sequential tickets. **Default is Yes.**

```
Enable analysis cache?
Caches project-level architecture analysis (file structure, dependencies, patterns) so subsequent tickets skip redundant discovery.
Cache is stored at $N1_HOME/cache/project-snapshot.md and auto-invalidated on structural changes.
1 — Yes (default)
2 — No
```

**If 2 (No):**
```json
{
  "analysisCache": {
    "enabled": false
  }
}
```

**If 1 (Yes) or default:**

Detect structural files by scanning the repo root for known markers:
```bash
# Check which structural file patterns actually exist in this repo
for pattern in package.json Cargo.toml go.mod pyproject.toml CLAUDE.md Dockerfile docker-compose.yml ".github/workflows/*"; do
  ls $pattern 2>/dev/null
done
```

Use detected files plus the defaults from `defaults/analysis-cache.json` to populate `structuralFiles`. Write:
```json
{
  "analysisCache": {
    "enabled": true,
    "ttl": "4h",
    "neutralThreshold": 15,
    "structuralFiles": ["<detected patterns + defaults>"]
  }
}
```

### On reconfiguration (n1-init re-run):

If `analysisCache` already exists in the current config, show current state and offer:
```
Current analysis cache:
  enabled → <true/false>
  ttl → <value>
  neutralThreshold → <value>
  structuralFiles → <count> patterns

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, re-detect structural files if currently disabled.
- **3** → set `enabled: false`, preserve other settings.

If `analysisCache` is absent from the current config, run the fresh-setup flow above.

## Plan Review Configuration

Use defaults. **Do NOT ask** the user about this unless they explicitly requested plan review customization when invoking n1-init.

- `reviewPlan: true` — after plan creation, solution-architect is re-spawned in fresh context to review the plan against specific adversarial criteria with codebase access
- `requirePlanApproval: false` — if the plan review passes (clean or self-fixed), proceed to implementation without a user checkpoint

```json
{
  "planReview": {
    "reviewPlan": true,
    "requirePlanApproval": false
  }
}
```
