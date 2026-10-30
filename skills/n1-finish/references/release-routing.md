# Step 6: Release Routing

Read from `steps/06-cleanup.md` only when the entry printed `release.enabled=true` and the merge succeeded, after printing the report; it is not read at entry.

<!-- n1-release is never invoked automatically regardless of autonomy mode (NP-71). The steps below are always interactive/suggestion-only. -->
**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, use the `mechanicalPrompts` value printed at entry; only when it is missing, read it via Bash (source `lib/config.sh` first):

```bash
MP=$(n1_autonomy_val 'mechanicalPrompts')
```

**If `MP` is `auto`:** skip the question below (the report's `Next (manual)` line already points at `/n1:n1-release`).

Write a Decision Ledger row to overview.md:
`| finish | mechanical | C | [auto] | Release now? | Suggest /n1:n1-release | Ask user | mechanicalPrompts=auto | --- |`

**If `MP` is `ask` (default):** ask:

```
Release this now?
No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Now: run /n1:n1-release (I will suggest it; you invoke it)
2 — Later: nothing recorded
3 — Batch: queue this ticket for the next release
```

- **1** → report `Next: /n1:n1-release` and STOP — do NOT invoke it yourself; releases are human-initiated.
- **2** → nothing to do.
- **3** → read `<N1_ROOT>/skills/n1-finish/references/release-batching.md` for the append procedure.
