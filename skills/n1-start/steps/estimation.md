
**Gate:** `n1_config_val '.estimation.enabled'` returns `true`. If absent, `false`, or not exactly `true` → skip silently.

> The gate key (`estimation.enabled`) and its default (`false`) are declared in `pipeline.json` `gates[]` — this inline read must match that declaration.

When the gate passes, run estimation at the appropriate pipeline point:
- **Simple tasks:** after Complexity Decision routes to simple, before IMPLEMENT
- **Complex tasks:** after Plan Review (4b), before Plan Checkpoint

**Estimation procedure:**

1. **Load mapping.** Read `estimation.mapping` from `$N1_HOME/config.json`. For any tier (XS/S/M/L/XL) not present in the project config, load the default from `defaults/estimation.json` in the N1 plugin directory. Merge: project overrides win, defaults fill gaps.

2. **Read context.** Load from `$N1_HOME/memory/<ID>/`:
   - Always: `ticket.md`, `analysis.md`, `brainstorm.md`
   - Complex path only (when `plan.md` exists): `plan.md`

3. **Classify complexity tier.** Evaluate the context and assign exactly one tier — XS, S, M, L, or XL — using these signals:
   - **Scope:** file count, component/module count, whether changes cross subsystem boundaries
   - **Infrastructure:** database migrations, new services or dependencies, configuration changes
   - **Testing:** new test suites required vs. extending existing, integration test needs
   - **Uncertainty:** new technology or unfamiliar patterns, external dependency risks, ambiguities from ticket.md or analysis.md

   Tier reference (for classification, not output):
   | Tier | Characteristics |
   |------|-----------------|
   | XS | Config change, typo, single-line fix |
   | S | Single file, clear scope, no migrations |
   | M | 2-5 files, may need tests, straightforward |
   | L | Multiple files, migrations, new tests |
   | XL | Cross-cutting, architectural, multi-subsystem |

4. **Map tier to time.** Look up the classified tier in the merged mapping table to get the time estimate string.

5. **Generate basis.** Write one sentence explaining why this tier was chosen, referencing concrete signals from the context (e.g., "4 files affected, includes new tests, no migrations").

6. **Write to memory.** Append an Estimation section to `$N1_HOME/memory/<ID>/overview.md`. Also update the checkbox `[x] Estimation` and set `step: estimation` in the frontmatter.

   ```markdown
   ### Estimation
   **Complexity:** <TIER> (<Full Name>)
   **Estimated delivery:** <time>
   **Basis:** <one sentence>
   ```

   Full names: XS = "Extra Small", S = "Small", M = "Medium", L = "Large", XL = "Extra Large".

7. **Write to tracker description** (conditional). Run ONLY when ALL conditions are met:
   - A tracker ticket ID exists
   - `tracker.mcp` is not null
   - `tracker.operations.editTicket` exists
   - `estimation.writeToTracker` in config is not `false` (default `true`)

   Process:
   a. Fetch current description via `mcp__<tracker.mcp>__<tracker.operations.readTicket>` with the ticket ID. If the read fails, log "⚠ Could not read ticket for estimation — skipping description update" and skip to step 8 (still attempt time field write).
   b. Check for `*Estimated by N1*` marker in the current description. If present, skip description append (idempotent).
   c. Append estimation block to description:
      ```
      ---
      *Estimated by N1*

      **Complexity:** <TIER> (<Full Name>)
      **Estimated delivery:** <time>
      **Basis:** <one sentence>
      ```
   d. Call `mcp__<tracker.mcp>__<tracker.operations.editTicket>`. Use exactly `mcp__<tracker.mcp>__` as the tool prefix — the value from config, not from the tool list.
      - If `tracker.type == "jira"`: with `cloudId` (resolve via `mcp__<tracker.mcp>__getAccessibleAtlassianResources` if not cached), `issueIdOrKey`: `<ticketId>`, `description`: `<current description + appended block>`
      - Else (`tracker.type == "youtrack"`): with `issueId`: `<ticketId>`, `description`: `<current description + appended block>`
   e. If the MCP call fails: log "⚠ Estimation description update failed: <reason>" and continue — non-blocking.

8. **Write to tracker time field** (conditional). Same gating conditions as step 7.

   Call `mcp__<tracker.mcp>__<tracker.operations.editTicket>`. Use exactly `mcp__<tracker.mcp>__` as the tool prefix.
   - If `tracker.type == "jira"`: with `cloudId`, `issueIdOrKey`: `<ticketId>`, `timetracking`: `{ "originalEstimate": "<time>" }`
   - Else (`tracker.type == "youtrack"`): with `issueId`: `<ticketId>`, set the `Estimation` field to `<time>` (period format)

   If the MCP call fails: log "⚠ Estimation time field update failed: <reason>" and continue — non-blocking.

9. **Report.** Log: "Estimated complexity: **<TIER>** — <time>. Basis: <one sentence>"

