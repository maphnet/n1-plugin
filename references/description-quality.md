### Description Quality Assessment & Enrichment (tracker ticket mode only)

**Gate:** Run ONLY when ALL of: `enrichmentEnabled` is true, `operations.editTicket` exists, and the ticket was fetched successfully. If any condition fails, skip entirely — set Description Quality tier to "Skipped" in the output and proceed to distill.

**Idempotency:** If the fetched description already contains the marker `*Structured by N1*` or `*Restructured by N1*`, skip enrichment — set tier to "Adequate (already enriched)" and proceed. `Normalized by N1` (Title & Form Repair, including one just written; match the text regardless of `*` or `_` emphasis) counts the same. `Refined by N1` (n1-refine's block) counts the same, with the same emphasis rule.

`*Briefed by N1 (queue plan)*` (n1-queue's plan-time brief) is not an idempotency marker; grade briefed tickets normally.

**Stale-write guard:** the tracker writes in this section and in Title & Form Repair replace whole fields, so re-fetch the ticket immediately before each write. If its title or description differs from the copy the new text was built from (that copy includes any field this run's earlier repair already wrote), skip the write, keep the original title and normal grading, set Action to "Skipped (ticket changed)", and proceed. In queue children run § Gate, then § Before the write: its mark, then this re-fetch (the capture hook snapshots it), then the update and § After the write.

**Queue children:** wrap every tracker description update below (Title & Form Repair step 4, Empty/Skeletal step 3, Weak step 2) in `references/desc-hash-chain.md` under the plugin root (`source ~/.n1/preamble.sh` sets `$N1_ROOT`): run § Gate, then § Before the write (mark, then fetch the description you build on), § After the write once the update succeeds. § Gate is a no-op outside queue runs.

Run this assessment AFTER the Fetch section has populated context data (step 1) but BEFORE the final distill (step 9). The analysis in steps 7-8 runs on the ORIGINAL description regardless of enrichment outcome — enrichment writes to the tracker, not to the analyst's working copy.

**A. Determine ticket type** from the tracker's type/issue-type field. Map to: `bug`, `feature`, `task`, or `improvement`. If unavailable, infer from the title and description content.

**B. Evaluate against type-aware minimum viable sections:**

| Type | Required sections |
|------|------------------|
| Bug | steps to reproduce, actual vs expected behavior, environment, severity |
| Feature/Story | user context, acceptance criteria, scope boundaries |
| Task/Improvement | definition of done, acceptance criteria |

**C. Assign quality tier** (evaluate in order — first match wins):

| Tier | Condition |
|------|-----------|
| **Empty** | Description is blank, whitespace-only, or contains only boilerplate (e.g., just a template with no filled-in content) |
| **Skeletal** | Description exists but has ≤1 meaningful sentence OR is missing acceptance criteria entirely |
| **Weak** | Description has content but ≥2 ambiguities detected OR missing ≥2 type-specific required sections |
| **Adequate** | Everything else — description has meaningful content with acceptance criteria and ≤1 ambiguity |

**Jira formatting rule:** When `cloudId` is present (Jira tracker), all content written to the tracker via MCP must use plain bullets (`- criterion`) instead of checkbox syntax (`- [ ] criterion`). Jira does not support GitHub-flavored Markdown checkboxes and silently strips the brackets, leaving empty bullets. This rule applies ONLY to content sent to the tracker — the internal `ticket.md` output format is unchanged.

**D. Act on the tier:** Adequate → skip enrichment, proceed to distill. When the tier is Empty, Skeletal or Weak, read `references/description-enrichment.md` first and follow it.

**E. Record the tier and action** for the Description Quality output section below.
