# Procedure: Follow-up Filing

Hands-off runs file the follow-up tickets the pipeline would otherwise offer (N1-102). Producers append candidates to `## Follow-ups` in `$N1_HOME/memory/<ID>/overview.md`. n1-start FINALIZE MEMORY runs § File once, before Gate 3. Ask mode (`qualityEscalations` other than `auto-accept`) never appends or files: proposals stay offers, as before. Never dispatches a persona. Never blocks: every failure warns and continues.

## § Append

Producers: review fix (`review`), QA fix (`qa`), n1-pr Codex step (`codex`), FINALIZE MEMORY (`finalize`). Only when `qualityEscalations=auto-accept`. Keep the usual report text; the line is added on top of it.

Add one line per candidate under `## Follow-ups` at the end of overview.md (create the heading if absent). Use the file-write mechanism, never through a shell command: titles and reasons are model or reviewer text. Line format: `- <title, ≤80 chars> | <one-line reason, with the finding ID if any> | <source>`

Skip a candidate whose title is already in the section. A title never starts with `[` (a leading `[SEC-1]` would read as a filed marker); put the finding ID in the reason. Prefix the reason with `Security-relevant:` for `[SEC-N]` findings.

## § File

### 1. Gate

```bash
source ~/.n1/preamble.sh
printf 'QE=%s\nTRACKER_MCP=%s\nTRACKER_TYPE=%s\nPROJECT_KEY=%s\nCLOUD_ID=%s\n' "$(n1_autonomy_val 'qualityEscalations')" "$(n1_config_val '.tracker.mcp')" "$(n1_config_val '.tracker.type')" "$(n1_config_val '.tracker.projectKey')" "$(n1_config_val '.tracker.cloudId')"
printf 'CREATE_OP=%s\nLINK_OP=%s\nCOMMENT_OP=%s\n' "$(n1_config_val '.tracker.operations.createIssue')" "$(n1_config_val '.tracker.operations.linkIssues')" "$(n1_config_val '.tracker.operations.addComment')"
```

Read every value from the output. `CREATE_OP` comes from `tracker.operations.createIssue`, `LINK_OP` from `tracker.operations.linkIssues`, `COMMENT_OP` from `tracker.operations.addComment`.

- `QE` is not `auto-accept`, or `## Follow-ups` has no candidate lines: skip silently. Gate 3 prints no `Follow-ups:` line.
- `TRACKER_MCP` is empty: file nothing. Every open candidate is unfiled and stays in overview.md. Go to § 4.
- `CREATE_OP` empty: use `createJiraIssue` (Jira) or `create_issue` (YouTrack).
- `<ID>` does not match `^[A-Z][A-Z0-9_]*-[0-9]+$` (provisional ID such as `sentry-123`, no tracker ticket yet): still create, but omit `Follow-up of <ID>.`, skip step 4 (link) and § 3 (comment); Gate 3 still reports.

### 2. Per candidate

Open candidates are the lines that do not start with `- [`. Process at most 5 per run (fixed cap); the rest are unfiled. Read `pr_url` from `## Pending`. For each open candidate, in order:

1. **Duplicate check.** Follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=create`, `TEXT=<title> — <reason>`, `SELF_ID` and `OVERVIEW` empty. Hands-off takes its unattended branch, so there is no prompt. If `MATCHES` has a `duplicate` row, do not create. Rewrite the line as `- [<HIT_ID> existing] <title> | ...`, link `<HIT_ID>` Relates to `<ID>` as in step 4 (best effort), and go to the next candidate.
2. **Create** via `mcp__<TRACKER_MCP>__<CREATE_OP>`:
   - summary = title
   - description = reason, then `Follow-up of <ID>.`, then `PR: <pr_url>` (omit when empty)
   - type per `<N1_ROOT>/references/ticket-scope.md` § Free-form creation (Bug for a defect; otherwise Task unless the candidate itself names several repositories or a decomposition)
   - parameter names per § Create-call parameters

   On failure, emit `> Warning: Follow-up not filed: <title>: <error>`, leave the line unmarked (a resume retries it), and continue.
3. **Mark.** Drop the new key unless it matches `^[A-Z][A-Z0-9_]*-[0-9]+$`. Rewrite the line as `- [<KEY>] <title> | ...` with the file-write mechanism, only after the create call succeeds.
4. **Link** `<KEY>` Relates to `<ID>` via `mcp__<TRACKER_MCP>__<LINK_OP>`:
   - YouTrack: map `Relates` → `relates to`, source = `<KEY>`, target = `<ID>`, using the tool's own argument names.
   - Jira: `cloudId`, `inwardIssue: { key: "<ID>" }`, `outwardIssue: { key: "<KEY>" }`, `type: { name: "Relates" }`.

   Then run duplicate-check § Apply Links with `SOURCE_ID=<KEY>` and the `DUP_LINKS` from step 1. If `LINK_OP` is empty or the call fails, emit `> Warning: Could not link <KEY> → <ID>: <error>` and continue.

### 3. Comment

Post via `mcp__<TRACKER_MCP>__<COMMENT_OP>` on `<ID>`, only when this run marked at least one line (a resume with nothing new posts nothing):

```
N1 follow-ups filed:
- <KEY> — <title>
Already tracked: <HIT_ID> — <title>   (omit if none)
Unfiled: <title>[, <title>...]        (omit if none)
```

If `COMMENT_OP` is empty or the call fails, emit `> Warning: Follow-up comment not posted on <ID>: <error>` and continue.

### 4. Report

Return this line for Gate 3, listing every marked key in the section (including earlier runs):

`Follow-ups: <KEY>[, <KEY>...][ (existing: <HIT_ID>...)][ (+N unfiled)]`

Use `Follow-ups: none filed (+N unfiled)` when nothing is marked.
