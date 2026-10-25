<!-- Purpose: Configure autonomy mode and analysis cache. -->

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

Then ask:

```
Run /n1:n1-finish automatically after PR + CI (autonomy.fullAuto)?
N1 still merges only with finishWork.mergeOnFinish: true; otherwise the chained finish stops on the open PR.
Queue and headless runs merge only when both keys are true.
1 — No (Recommended): matches the code default false of n1_fullauto_enabled (lib/config.sh) and of finishWork.mergeOnFinish (13-write-config.md).
2 — Yes
```

- **1** → add `"fullAuto": false` to the `autonomy` object. **2** → add `"fullAuto": true`. Always write a JSON boolean, never a string.

### On reconfiguration (n1-init re-run):

If `autonomy` already exists in the current config:
- If it contains `"mode"` (with or without `"fullAuto"`): show the current values and re-ask both questions.
- If it contains legacy sub-keys (no `"mode"` key): show a migration note —
  `"Your config uses legacy autonomy keys. Reconfiguring will write the new single-key format."` — then re-ask.

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
    "structuralFiles": ["<detected patterns + defaults>"]
  }
}
```

### On reconfiguration (n1-init re-run):

If `analysisCache` already exists in the current config, show current state and offer:
```
Current analysis cache:
  enabled → <true/false>
  structuralFiles → <count> patterns

1 — Keep current
2 — Enable
3 — Disable
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, re-detect structural files if currently disabled.
- **3** → set `enabled: false`, preserve other settings.

If `analysisCache` is absent from the current config, run the fresh-setup flow above.

