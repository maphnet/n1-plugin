<!-- Purpose: Configure task complexity estimation and delivery time writing. -->

## Estimation Configuration

Ask whether N1 should estimate task complexity and write delivery time to the tracker. **Default is No.**

```
Enable estimation for tickets?
Estimates task complexity and writes delivery time to tracker.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "estimation": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Set `estimation.enabled: true` and `estimation.writeToTracker: true`.

Show the default mapping table:
```
Default delivery time mapping:
  XS  30m   (config change, typo, single-line fix)
  S   2h    (single file, clear scope, no migrations)
  M   6h    (2-5 files, may need tests, straightforward)
  L   2d    (multiple files, migrations, new tests)
  XL  5d    (cross-cutting, architectural, multi-subsystem)

Customize mapping? 1 — Use defaults (recommended) / 2 — Customize
```

**If 1 (Use defaults):** omit `mapping` from the config entirely — the orchestrator loads defaults from `defaults/estimation.json` at runtime.

**If 2 (Customize):** ask for each tier value as a time string (e.g., `"4h"`, `"3d"`). Only store tiers the user actually changed — partial overrides merge with defaults at runtime.

```json
{
  "estimation": {
    "enabled": true,
    "writeToTracker": true,
    "mapping": {
      "M": "8h",
      "L": "3d"
    }
  }
}
```

### On reconfiguration (n1-init re-run):

If `estimation` already exists in the current config, show current state and offer:
```
Current estimation:
  enabled → <true/false>
  mapping → <default/custom>

1 — Keep current
2 — Enable
3 — Disable
4 — Update mapping
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, `writeToTracker: true`. If mapping was not previously set, leave it (uses defaults).
- **3** → set `enabled: false`. Remove `writeToTracker` and `mapping` keys.
- **4** → show current mapping (merged with defaults), ask for changes. Only store overridden tiers.

If `estimation` is absent from the current config, run the fresh-setup flow above.
