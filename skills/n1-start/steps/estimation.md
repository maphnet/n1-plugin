
**Gate:** `n1_config_val '.estimation.enabled'` returns exactly `true`. Otherwise skip silently.

```bash
source "$N1_ROOT/lib/preamble.sh"
n1_verify_dependencies "$N1_HOME/memory/$ID" analysis.md || { echo "ERROR: analysis.md missing — cannot estimate" >&2; exit 1; }
GATE_ENABLED=$(n1_config_val '.estimation.enabled' 2>/dev/null || echo 'false')
n1_record_decision estimation-gate "$( [ "${GATE_ENABLED:-false}" = "true" ] && echo true || echo false )" '{"config":"estimation.enabled"}' "enabled=${GATE_ENABLED:-false}"
```

**When:** direct tasks — after Planning Need Routing routes to direct, before IMPLEMENT. Plan tasks — after Plan Review (4b).

**Procedure:**

1. **Load mapping.** Read `estimation.mapping` from `$N1_HOME/config.json`. Missing tiers: load defaults from `defaults/estimation.json`. Project overrides win.

2. **Read context:** ticket.md, analysis.md, brainstorm.md (if present — absent on simple-path; use analysis.md signals alone). Complex path only: plan.md.

3. **Classify tier:** one of XS/S/M/L/XL using scope (file/module/subsystem count), infrastructure (migrations, new services), testing (new suites vs extending), uncertainty (new tech, external deps, ambiguities).

   | Tier | Characteristics |
   |------|-----------------|
   | XS | Config change, typo, single-line fix |
   | S | Single file, clear scope, no migrations |
   | M | 2-5 files, may need tests, straightforward |
   | L | Multiple files, migrations, new tests |
   | XL | Cross-cutting, architectural, multi-subsystem |

4. **Map tier → time.** Look up in merged mapping table.

5. **Basis.** One sentence citing concrete signals (e.g., "4 files affected, includes new tests, no migrations").

6. **Write to memory.** Append to `$N1_HOME/memory/<ID>/overview.md`, update `[x] Estimation`, set `step: estimation`.
   ```markdown
   ### Estimation
   **Complexity:** <TIER> (<Full Name>)
   **Estimated delivery:** <time>
   **Basis:** <one sentence>
   ```
   Full names: XS=Extra Small, S=Small, M=Medium, L=Large, XL=Extra Large.

7. **Write to tracker description** (ALL required: ticket ID exists + `tracker.mcp` + `editTicket` + `estimation.writeToTracker !== false`): fetch current description; check for `*Estimated by N1*` (skip if present); append block with `---\n*Estimated by N1*\n**Complexity:**...\n**Estimated delivery:**...\n**Basis:**...`; call `editTicket`. Non-blocking on failure.

8. **Write to tracker time field** (same gating): call `editTicket` with `timetracking.originalEstimate` (Jira) or `Estimation` field (YouTrack). Non-blocking.

9. **Report:** "Estimated complexity: **<TIER>** — <time>. Basis: <one sentence>"
