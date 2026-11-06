# Step 6: Release Routing

Read from `steps/06-cleanup.md` only when the entry printed `release.enabled=true` and the merge succeeded, after printing the report; it is not read at entry.

<!-- n1-release is never invoked automatically (NP-71). This step is suggestion-only. -->
**Release routing (when `release.enabled` is `true` and the merge succeeded):** after printing the report, ask nothing: the report's `Next (manual)` line already points at `/n1:n1-release`.

Write a Decision Ledger row to overview.md:
`| finish | mechanical | C | [auto] | Release now? | Suggest /n1:n1-release | Ask user | auto | --- |`
