# Procedure: Resume

## Post-Compaction Recovery

After compaction, session-start hook injects ORCHESTRATOR STATE into `additionalContext`.

**Must:**
1. Read ORCHESTRATOR STATE — authoritative over compacted summary.
2. Use those values (tracker type, MCP prefix, worktree, step routing, loop counters), not the compacted summary.
3. If `Task context:` non-empty: print **Gate 1** (resume variant, `procedures/output-gates.md § Gate 1`).
4. If missing: `source ~/.n1/preamble.sh` re-resolves N1_HOME; read config keys via `n1_*_val` helpers.

## Memory Check

Check if `$N1_HOME/memory/<input>/overview.md` exists.

**Exists:** read step from frontmatter.
```bash
source ~/.n1/preamble.sh
TYPE=$(n1_read_type "$N1_HOME/memory/$ID/overview.md")
```
**ID reuse check** — if `<input>` is a tracker ID, `step` is `done`, and `readTicket` is configured: fetch the ticket (error → skip) and write its title to `$N1_HOME/memory/.fresh-title-$ID.txt` (a sibling of `$N1_HOME/memory/$ID/`, so an archive can't sweep it in) via the file-write mechanism, never a shell string (untrusted text, NP-203 SEC-1).
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/memory.sh"
ARCHIVED=$(n1_memory_reuse_check "$N1_HOME/memory/$ID" "$(cat "$N1_HOME/memory/.fresh-title-$ID.txt")")
rm -f "$N1_HOME/memory/.fresh-title-$ID.txt"
[ -n "$ARCHIVED" ] && n1_archive_stale_branch "<TARGET>" "${ARCHIVED##*/$ID}"
echo "ARCHIVED=$ARCHIVED"
```
`<TARGET>` is the working branch for `<ID>` (as in `workspace-isolation.md`); renaming it keeps the new ticket off the old commits. Non-empty `ARCHIVED`: tell the user old memory moved there, continue as **Not exists**. Empty `ARCHIVED` (including a failed archive move): resume as today.

Step `escalated` + non-headless: print `## Escalations`, move to `inProgress` (if `tracker.statuses.blocked` set), reset step per `procedures/autonomy-headless.md`.

Step `escalated` + headless with `N1_ORCA_RESUME=1` (a queue resumed this ticket in its existing worktree, N1-271; the runner's stale-step guards end with the first overview.md write, so do this before any other write, and before `n1_busy_guard`. The step reset is the first overview.md write):
1. Reset `step` to the last completed step (the only reset rule `procedures/autonomy-headless.md` gives, and its text covers `N1_HEADLESS` unset). Do not move the tracker status yet: the ask-mode answer branch moves the ticket to `inProgress`.
2. Re-ask only the last `## Escalations` item (`## Escalations` is append-only and keeps questions already answered in ask mode). Do not rerun the escalate steps that append a line, move the ticket to blocked or release the queue tag. Go straight to the `ask` branch of `procedures/autonomy-headless.md` (write the question file, then `n1_orca_ask` when `ORCA_CHILD=yes`, then handle the answer). Take `step` and the question and options from the item. Set `category` from the stop list, or `none` when none matches. Set `recommended` to `""` with the standard no-recommendation rationale.
3. The queue row then parks `awaiting-human`, and `/n1:n1-queue --answer <ID> <text>` reaches it. Every other headless `escalated` resume is unchanged.

```bash
source ~/.n1/preamble.sh
n1_busy_guard "$N1_HOME/memory/$ID/overview.md" "$ID"
```
Exit 3 (headless): STOP.

`TYPE=="investigation"`: skip workspace isolation; else run `procedures/workspace-isolation.md § Workspace Decision` (`FRESH=0`). Read loop counters:
```bash
source ~/.n1/preamble.sh
n1_read_frontmatter "$N1_HOME/memory/$ID/overview.md" "qa_fix_cycle"
```
(Repeat for `tq_fix_cycle`, `review_fix_cycle`, `clean_passes`, `local_test_fix_cycle`, `ci_fix_cycle`.) Print Gate 1 (resume variant). Read `## Context`:
```bash
CONTEXT_SECTION=$(sed -n '/^## Context$/,/^## /{/^## Context$/d;/^## /d;p}' "$N1_HOME/memory/$ID/overview.md")
```
If empty: skip Gate 1. Else populate template from frontmatter and print.

**Not exists:** fresh start. Create `$N1_HOME/memory/<ID>/`.

## Loop-Counter Durability

Loop counters live in overview frontmatter (same keys as above). Increment in file as loop turns; read back on resume.

Overview is source of truth. Step writes output FIRST, then updates `step:`/checkbox LAST. Artifact writes are idempotent.

**Dependency integrity guard:**
```bash
source ~/.n1/preamble.sh
n1_verify_dependencies "$N1_HOME/memory/$ID" ticket.md analysis.md
```
Missing/empty → STOP and report.
