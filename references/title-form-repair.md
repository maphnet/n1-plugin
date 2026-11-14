### Title & Form Repair (tracker ticket mode only)

Gate: the same as § Description Quality Assessment & Enrichment below (`enrichmentEnabled` true, `operations.editTicket` exists, ticket fetched). Runs at the same position as that assessment (after Fetch, before step 9) and before it, as part of step 3. It fixes summaries and form dumps that feedback/bug-report flows leave behind (N1-61). n1-queue applies steps 1, 2 and 4 at plan time (`skills/n1-queue/steps/preview.md` § Plan-Resolve 1).

1. **Poor title** means any of these: empty or whitespace-only; the whole trimmed summary is, case-insensitively, one of `error bug issue todo test fix help problem untitled none na tbd`; or ≤2 words while the description has a line starting with `Title:` whose value has more words. The replacement is that embedded `Title:` value, unless it is itself empty or on the placeholder list. Otherwise use a ≤10-word title distilled from the description. If there is no usable replacement, leave the title alone. A title carries no marker: once repaired it is no longer poor, so a re-run makes no edit. A poor title with a non-form description is repaired on its own (title-only write, no description change).
2. **Poor description** means a raw form dump: ≥2 lines starting with `Type:`, `Title:`, `Area:` or `Details:`, no `Normalized by N1` text yet (match it with or without `*` or `_` emphasis around it), and no `Acceptance Criteria` heading or checklist already in the description. New description = original + `\n\n` + this block. Keep the original text. Write 2-4 criteria inferred from the form fields and never invent scope. Use plain bullets for both trackers:
   ```
   ---
   *Normalized by N1*

   ### Core Ask
   <1-2 sentences>

   ### Acceptance Criteria
   - <criterion>
   ```
   Empty or Skeletal descriptions that are not form dumps stay on the enrichment path below.
3. **Queue child:** if step 1 or 2 found something, run `references/desc-hash-chain.md` § Gate first (one Bash call; reuse its result for the description wrapper in § Description Quality Assessment & Enrichment "Queue children", do not run it twice, the Bash budget is 2). On `SKIP` (interactive n1-start, where `N1_QUEUE_RUN_ID` is unset) nothing changes: the title is written. On `CHAIN`, drop the title part. A title edit in a queue child breaks the hash chain, and queue plan time already repaired it. If only the title part was found, there is nothing to write.
4. **Write once:** immediately before the write, re-fetch the ticket (the Stale-write guard below). Then make one `mcp__<trackerMcp>__<operations.editTicket>` call carrying only the changed fields. Jira: `cloudId`, `issueIdOrKey`, `summary`, `description`. YouTrack: `issueId`, `summary`, `description`. Pass them as structured tool arguments, never through a shell string. If the call fails, log "⚠ Enrichment failed: <reason>" and proceed. Repair is non-blocking.
5. **On success,** use the repaired title as **Title:** in ticket.md (the `**Title:**` line carries the repaired title, not the original) and as `title` in the intake-result line. When a queue child dropped the title write, still use the recovered title locally (as today). Set Action to "Repaired (<title and/or description>)". When the description was repaired, the new marker makes the grading below Adequate (already enriched); a title-only repair leaves the normal grading in place.
