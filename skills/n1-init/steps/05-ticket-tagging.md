<!-- Purpose: Configure service name tagging for N1-created tickets. -->

## Ticket Tagging Configuration

Ask whether to tag N1-created tickets with a service (repo) name. **Default is No** — do not enable unless the user opts in.

```
Tag created tickets with a service name? (e.g. "payments-api | Add CSV export")
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "ticketTagging": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Derive a default service name, then confirm it:
1. Run `git remote get-url origin 2>/dev/null`. If it succeeds, take the last path segment and strip a trailing `.git` (e.g. `git@github.com:org/payments-api.git` → `payments-api`, `https://github.com/org/payments-api` → `payments-api`).
2. If there is no `origin` remote, fall back to the current directory's base name.
3. Show and confirm:
   ```
   Detected service name: <detected>
   (from git remote origin)

   Use this? 1 — Yes / 2 — Enter a different name
   ```
   - **1** → use `<detected>`.
   - **2** → ask: "Service name:" and use the entered value (trimmed).

```json
{
  "ticketTagging": {
    "enabled": true,
    "service": "<confirmed name>"
  }
}
```

### On reconfiguration (n1-init re-run):

If `ticketTagging` already exists in the current config, show it and offer:
```
Current ticket tagging:
  enabled → <true/false>
  service → <value or "(none)">

1 — Keep current
2 — Update service name
3 — Disable tagging
```
- **1** → leave unchanged.
- **2** → run the derive+confirm flow above, set `enabled: true`.
- **3** → set `{ "enabled": false }`.

If `ticketTagging` is absent from the current config, run the fresh-setup flow above.
