# Description Enrichment (tiers Empty, Skeletal, Weak)

Read from `references/description-quality.md` step D. Steps A-C, the Jira formatting rule and the queue-children hash chain are there.

**D. Act on the tier:**

- **Adequate** → skip enrichment, proceed to distill.

- **Empty** or **Skeletal** → generate enrichment content and update the tracker silently:
  1. Construct append content — infer from the title, ticket type, and any available comments. Use plain bullets for Jira (see Jira formatting rule above), checkboxes for YouTrack:
     ```
     ---
     *Structured by N1*

     ### Acceptance Criteria
     - [ ] <inferred criterion 1>       ← YouTrack
     - <inferred criterion 1>           ← Jira (when cloudId is present)

     ### <Type-specific section(s) — only sections that are missing>
     <content inferred from title, comments, and available context>
     ```
     Only add sections the description is missing. If it already has informal acceptance criteria, do not duplicate them.
  2. Construct the full new description: `<original description>\n\n` + append content. For Empty tier where original is blank, omit the leading `\n\n` — start with the content directly.
  3. Update the tracker:
     - **Jira:** Call `mcp__<trackerMcp>__<operations.editTicket>` with `cloudId`: `<cloudId>`, `issueIdOrKey`: `<ticketId>`, `description`: `<full new description>`
     - **YouTrack:** Call `mcp__<trackerMcp>__<operations.editTicket>` with `issueId`: `<ticketId>`, `description`: `<full new description>`
  4. If the MCP call fails: log "⚠ Enrichment failed: <reason>" and proceed — enrichment is non-blocking. Never stop the pipeline for an enrichment failure.

- **Weak** → generate a full rewrite and update the tracker silently:
  1. Construct the rewrite. Use plain bullets for Jira (see Jira formatting rule above), checkboxes for YouTrack:
     ```
     <details><summary>Original description</summary>

     <original text>

     </details>

     ### Core Ask
     <1-2 sentences summarizing what needs to happen>

     ### Acceptance Criteria
     - [ ] <criterion>                  ← YouTrack
     - <criterion>                      ← Jira (when cloudId is present)

     ### <Type-specific sections — all required sections for this ticket type>
     <content>

     ---
     *Restructured by N1*
     ```
  2. Update the tracker silently:
     - **Jira:** Call `mcp__<trackerMcp>__<operations.editTicket>` with `cloudId`: `<cloudId>`, `issueIdOrKey`: `<ticketId>`, `description`: `<full rewrite>`
     - **YouTrack:** Call `mcp__<trackerMcp>__<operations.editTicket>` with `issueId`: `<ticketId>`, `description`: `<full rewrite>`
  3. If the MCP call fails: log "⚠ Enrichment failed: <reason>" and proceed — enrichment is non-blocking. Never stop the pipeline for an enrichment failure.

