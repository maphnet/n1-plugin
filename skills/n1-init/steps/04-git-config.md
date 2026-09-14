<!-- Purpose: Configure default branch, branch pattern, and PR mode. -->

## Git Configuration

Detect **defaultBranch** automatically:
- Run `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'`
- Fall back to checking `main`/`master` branch existence

**branchPattern:**
- If a tracker was configured above → already set during Tracker Setup (branch prefix question)
- If no tracker (None) → default to `feature/{slug}`

```json
{
  "git": {
    "defaultBranch": "main",
    "branchPattern": "<from tracker setup or feature/{slug}>"
  }
}
```

## PR Mode Configuration

Ask how N1 should handle PRs. **Default is Draft.**

```
How should N1 handle PRs?
1 — Draft (default) — create PR immediately as draft
2 — Ready — create PR ready to merge
```

**If 1 (Draft) or default:**
```json
{
  "git": {
    "prMode": "draft"
  }
}
```

**If 2 (Ready):**
```json
{
  "git": {
    "prMode": "ready"
  }
}
```

### On reconfiguration (n1-init re-run):

If `git.prMode` already exists in the config, show its current value and offer. If only `git.draftPR` exists (legacy config), derive the display value: `true` → `"draft"`, `false` → `"ready"`. If neither key exists, treat as `"draft"` (the default).

```
PR mode: <draft/ready>
1 — Keep current
2 — Draft (create PR as draft)
3 — Ready (create PR immediately)
```
- **1** → leave unchanged.
- **2** → set `prMode: "draft"`.
- **3** → set `prMode: "ready"`.

When writing any of options 2–3, also remove the `git.draftPR` key if it is present in the config (it is superseded by `prMode`).
