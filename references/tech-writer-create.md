# Tech Writer: Create Mode

Read when `mode` is absent or `create`. Input, Tool Budget and Constraints stay in `agents/tech-writer.md`.

## Phase 1: Documentation Update

**`mode: reconcile` → skip Phase 1 and Phase 2; go straight to Reconcile Mode.** Never edit, commit, or push repository files in reconcile mode.

**`phase: 2` → skip Phase 1 entirely** (no doc scan, edits, or commits) and start at Phase 2, reusing the doc update report from your prompt if given.

Discover and update documentation files affected by the code changes. This runs BEFORE PR content generation.

### Step 1: Extract Change Footprint

Run `git diff <default-branch>...HEAD --name-only` to get the full list of files changed on this branch. This is the change footprint — every file that was added, modified, or deleted.

### Step 2: Smart Scan for Documentation Files

Find documentation files that may need updates:

1. **Walk up directories** from each changed file — at each directory level, look for `*.md` files. For example, if `src/api/auth/handler.ts` changed, check `src/api/auth/`, `src/api/`, `src/`, and root.
2. **Always include** the root `README.md` if it exists.
3. **Apply config filters:**
   - If `docs.include` is set, add those paths to the scan list (additive — on top of smart-scan results).
   - If `docs.exclude` is set, skip files matching those glob patterns.
4. **Deduplicate** the resulting file list.

### Step 3: Cross-Reference Docs Against Diff

For each candidate documentation file:

1. **Read** the documentation file.
2. **Read** the diff (`git diff <default-branch>...HEAD`) for the relevant changed files.
3. **Read** `implementation.md` for context on what was implemented and why.
4. **Determine** whether the documentation references anything that changed — API signatures, configuration options, CLI flags, architecture descriptions, setup steps, feature lists, examples, etc.
5. **Assess confidence:**
   - **High** — the doc clearly references something that changed, and the correct update is unambiguous (e.g., a function signature in an API doc, a config key in a setup guide).
   - **Low** — the doc likely needs an update, but the correct change is uncertain or involves subjective judgment (e.g., architectural overview, conceptual explanation).
   - **None** — the doc does not reference anything that changed, or changes are irrelevant to the doc's content.

### Step 4: Confidence-Based Action

| Confidence | Action |
|-----------|--------|
| **High** | Update the file silently. No user interaction needed. |
| **Low** | Update the file with your best judgment, then flag it for reviewer attention. |
| **None** | Skip the file. Note it only if you considered it but decided no update was needed. |

In `confirm` mode, present all proposed changes to the user before applying and wait for approval. In `autonomous` mode, apply High and Low changes directly.

### Step 5: Apply Updates

- Use the **Edit** tool for surgical updates — change only the specific lines that need updating.
- **Preserve** the existing style, tone, formatting, and structure of each document.
- Do not rewrite sections unnecessarily — minimal, targeted changes only.
- If a new section is needed (e.g., documenting a new feature), use the **Write** tool or **Edit** tool as appropriate, matching the existing document's conventions.

### Step 6: Commit Documentation Changes

If any documentation files were updated:

```
git add <updated-doc-files>
git commit -m "docs: update documentation for <feature/ticket>"
```

Only commit documentation files — never include code changes in this commit.

### Step 7: Prepare Doc Update Report

Compile three lists for use in Phase 2:

- **Updated** — files that were updated with high confidence (no reviewer action needed).
- **Flagged** — files that were updated with low confidence (reviewer should verify the changes).
- **Needs review** — files that were skipped but may need manual attention (with a brief explanation of why).

## Phase 2: PR Content Generation

Generate the PR title and body from implementation context.

1. **Read overview.md** for ticket title, key decisions made during implementation, any escalations, and the `## Decision Ledger` table (if present).

2. **Read review.md** for review results — what was found and fixed during review. If it has `## Deferred Soft Findings`, add to `## Review Notes` one line `Deferred soft findings (<count>, not fixed):` followed by one bullet per finding (`[ID] file:line — title`), at most 10, then `(+K more in review memory)`. Omit `[SEC-N]` and security-class findings (auth, crypto, input validation, secrets, network/HTTP, (de)serialization, file/path handling, SQL/query, shell/command execution) from the bullets: give only a count, `plus K security notes kept in review memory`, never file:line. This list is mandatory and exempt from Lean Output. If review.md has `## For Human Review` (fix cap hit, findings open), add it to the PR body with its bullets; security-class findings keep `[ID]` and title only. Section is mandatory, exempt from Lean Output.

3. **Read qa.md** for test coverage summary and verification steps.

4. **Read local-testing.md** (if provided) for local end-to-end testing results — scenario pass/fail, evidence.

4b. **Read ticket.md** (if provided) for the original ticket description — extract a 1-2 sentence summary of the core ask or problem being solved. Skip this step if ticket.md was not provided.

5. **Merge verification items.** If local-testing.md was provided and its first line starts with `Local testing: not run` (N1-559: no live verification configured), skip a–d and f: all QA items become plain unchecked checkboxes (apply e when it applies), and the summary line is that first line verbatim, e.g. `Local testing: not run — no live verification configured for this project`. Otherwise, if local-testing.md was provided, build the unified verification checklist:

   **a. Match items.** For each local testing scenario, find the QA verification step that describes the same behavior (e.g., QA "Create user via API returns 201" matches local "Create user — POST /api/users, expected 201"). When uncertain whether two items match, do NOT merge them — keeping a near-duplicate is better than incorrectly marking a QA item as verified by the wrong scenario.

   **b. Apply results to matched items:**
   - Matched + PASS → `- [x] <QA description> *(locally verified — <evidence>)*`
   - Matched + FAIL → `- [ ] <QA description> *(local testing: FAILED — <detail>)*`

   **c. Collect unmatched items:**
   - Unmatched QA items → `- [ ] <description>` (no annotation)
   - Unmatched local scenarios: PASS → `- [x] <description> *(locally verified — <evidence>)*`, FAIL → `- [ ] <description> *(local testing: FAILED — <detail>)*`
   - Manual checklist items from local testing → `- [ ] <description> *(manual check)*`

   **d. Order the final list:**
   1. Locally verified (checked) — what's already proven
   2. Failed (unchecked with failure detail) — known issues
   3. Unverified (unchecked, no annotation) — reviewer needs to check
   4. Manual check items — human judgment required

   **e. Machine-inferred annotation pass.** When `description_quality` is `empty` or `skeletal`: for every plain unverified checklist item (`- [ ] <description>` with no trailing annotation), append ` *(machine-inferred, unconfirmed)*`. Items already annotated (locally verified, failed, manual check) keep their existing annotation unchanged. This signals that the acceptance criteria driving these checks were never ratified by a human reviewer.

   **f. Compute summary line.** Count automated scenarios from local-testing.md (exclude manual items). Determine verdict:
   - All pass → `Local testing: PASS — N/N automated scenarios passed`
   - Some fail → `Local testing: FAIL — X/N automated scenarios passed, Y failed`

   If local-testing.md was NOT provided, skip this step entirely — all QA items become plain unchecked checkboxes with no summary line.

6. **Render the Decision Ledger.** If overview.md contains a `## Decision Ledger` section with at least one data row, add a `## Decisions` section to the PR body. One bullet per row, ordered tier A → B → C, and `[auto]` before `[asked]` within a tier:
   - `- **[auto/asked] <question>** — <chosen>. *(<reason>)*` — include `(alternatives: <...>)` only for tier A rows.
   - Tier A rows are the ones the reviewer must actually judge — never omit them, even under the word budget. Tier C rows may be collapsed to a single line: `- N routine decisions made autonomously (see overview.md ledger)` when the body would otherwise exceed the 500-word budget.
   - The ledger table has a 9th column `Rungs Tried` (added in v2.90.0). Rows without a 9th cell are treated as `---` (backward compatible). Do not render `rungs_tried` in PR bullets — it is for telemetry only.
   If there is no ledger section or it has no rows, omit the `## Decisions` section entirely.

7. **Analyze diff stat** to understand the scope of changes (which areas of the codebase were touched).

7b. **Deployment actions.** Build a Before deploy list, a Before release list and an After deploy list from two sources, then merge them:
   - **ticket.md `### Deployment Actions`** (if present): keep each item's wording. Use the ticket's own split when it has one (Before deploy / Before release / After deploy). Items the ticket marks as release-time or prod-only go under Before release. Otherwise put config, secrets and migrations under Before deploy, and backfills, cache warm-ups and one-off scripts under After deploy. A ticket item that only verifies state is written as `Check:` (see Read-only checks below).
   - **Diff scan** (same base as step 7). Collect names added in this branch:
     ```bash
     git diff <base>...HEAD -U0 | grep -E '^\+[^+]' | grep -oE '(vars|secrets)\.[A-Za-z_][A-Za-z0-9_]*|process\.env\.[A-Za-z_][A-Za-z0-9_]*|[Gg]etenv\(.[A-Za-z_][A-Za-z0-9_]*|environ(\.get\(|\[).[A-Za-z_][A-Za-z0-9_]*|ENV\[.[A-Za-z_][A-Za-z0-9_]*' | sort -u
     git diff <base>...HEAD --name-only --diff-filter=A | grep -iE '(^|/)migrations?/' || true
     ```
     Strip each match to its bare name. Keep only names that are new in this branch, checked in one call: `for n in <names>; do git grep -qw -- "$n" <base> || echo "new:$n"; done`. Each new `secrets.X` (or any credential-like name) becomes `Manual: set secret X in <GitHub Actions secrets | the deploy environment>`. Each new `vars.X` becomes `Manual: set repository variable X`. Each new env var read becomes `Manual: set env var X in the deploy environment`. Each new migration file becomes `Manual: apply migration <file>`, unless the ticket gives the exact command. Diff-derived items go under Before deploy (the diff cannot show which steps are release-only; Before release items come from the ticket only).
   - **Merge:** drop a diff-derived item when a ticket item names the same resource.
   - **Secret values never appear**, only names. Any secret-involving item is written as `Manual:`, even when the ticket gives a command. If a ticket item contains a literal secret value, rewrite it as `Manual: set secret <NAME> ...` without the value.
   - **Read-only checks:** write `Check: <what to verify and the expected result>` (under After deploy unless the ticket places it) only for a verification that reads state and changes nothing: an endpoint returns 200, a `gh` or database query shows a value, a log line exists. Anything that writes, deploys, migrates, restarts, sets a value, or involves a secret stays `Manual:` or a shell command. n1-finish and n1-release run `Check:` items without asking, so a write labeled `Check:` would run unasked.
   - **Format:** one action per `- [ ]` line, with no nested bullets. Each item is a single backtick shell command (optionally followed by a short note), text starting with `Manual:`, or text starting with `Check:` (read-only verification only). n1-finish and n1-release parse these lines and tick them `[x]` as they run. Before release items are walked only by n1-release, before the tag push; n1-finish never offers them.
   - **Project rules** (if `RULES_BLOCK` given): for each rule whose clause requires an action at the deploy boundary, add one `- [ ]` row under Before deploy (same Format rules; names only, no secret values; drop a row that duplicates a ticket or diff item). Rules about docs apply in Phase 1; rules with no deploy action produce no row. Never copy rule text into the PR body beyond the row.
   - All lists empty → no section. Any list empty → omit that sub-heading.

8. **Compose** PR title and body in the output format below, incorporating the doc update report from Phase 1. When `body_file` is given, write the body (body only: no title, no `## PR Content` wrapper, no other wrapper tags) to `body_file` and the title (one line, no `###`) to `<body_file>.title`, both with the Write tool (the file-write mechanism, references/file-write-mechanism.md), and return only the title block plus `pr body written: <body_file>` (see Output Format). Without `body_file`, return title and body inline.

## Output Format

```markdown
## PR Content

### Title
[TICKET-ID] <imperative mood summary, under 70 chars>

### Body
## Summary
- <bullet 1: main change and why>
- <bullet 2: secondary change if applicable>
- <bullet 3: if applicable>

## Changes
- **<area/module>:** <what changed>
- **<area/module>:** <what changed>

## Deployment Actions

### Before deploy
- [ ] `<shell command>`
- [ ] Manual: <step — names only, never secret values>

### Before release
- [ ] Manual: <release-time step, e.g. prod-only — walked only by n1-release before the tag push>

### After deploy
- [ ] `<shell command>`
- [ ] Check: <read-only verification, e.g. the health endpoint returns 200>

## Verification

Local testing: PASS — N/N automated scenarios passed

- [x] <description> *(locally verified — <evidence>)*
- [ ] <description> *(local testing: FAILED — <detail>)*
- [ ] <description>
- [ ] <description> *(manual check)*

## Decisions
- **[auto] <question>** — <chosen>. *(<reason>)* (alternatives: <...>)
- **[asked] <question>** — <chosen>. *(<reason>)*

## Documentation
- **Updated:** <file> — <what was updated> (high confidence)
- **Flagged:** <file> — <what was updated, reviewer should verify> (low confidence)
- **Needs review:** <file> — <why this may need manual update> (skipped)

## Review Notes
<anything reviewers should pay attention to — architectural decisions, trade-offs, areas of uncertainty>

## Ticket
<1-2 sentence summary from ticket.md (if provided)>
<ticket_url from overview.md frontmatter — omit line if empty>
```

**Note:** With `body_file`, the `### Body` content goes to that file and the reply is only:

```markdown
## PR Content

### Title
[TICKET-ID] <imperative mood summary, under 70 chars>

pr body written: <body_file>
```

**Note:** Omit the Documentation section entirely if Phase 1 found no documentation files to update, flag, or note.

**Note:** Omit the Decisions section entirely when overview.md has no `## Decision Ledger` rows. Tier A entries are never dropped for budget reasons.

**Note:** Omit `## Deployment Actions` entirely when step 7b found no actions. Never drop or shorten an action to meet the 500-word budget.

**Note:** The `## Verification` section is always included. When local-testing.md was provided, include the summary line at top and apply evidence/failure/manual-check annotations per the merge rules in step 5. When local-testing.md was NOT provided, omit the summary line and evidence/failure/manual-check annotations — list QA items as plain unchecked checkboxes. In both cases, after building the checklist, apply the machine-inferred annotation pass from step 5e when `description_quality` is `empty` or `skeletal`:

```markdown
## Verification

- [ ] <QA verification step>
- [ ] <QA verification step>
```

- Copy the `### AC Coverage` table from `review.md` verbatim under a `#### Acceptance criteria` sub-heading, except foreign ticket keys, which are rewritten per the ticket-key hygiene constraint. Do not re-evaluate it.

