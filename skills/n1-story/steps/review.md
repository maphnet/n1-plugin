# Step 5: Review

## Section-by-Section Approval

Read `$MEMORY_DIR/story-design.md`. Present it to the user section by section for approval.

### Section order:

1. **Goal & Success Criteria** — present the `## Goal` and `## Success Criteria` sections
2. **Architecture Overview** — present the `## Architecture Overview` section
3. **Each Phase** — for each `### Phase N:` section, present the phase header, deliverables, dependencies, and all tasks within it
4. **Cross-Cutting Concerns** — present the `## Cross-Cutting Concerns` section
5. **Assumptions & Risks** — present the `## Assumptions & Risks` and `## Open Questions` sections

### Per-section interaction:

After presenting each section, ask: "Does this section look right? (1) Approve (2) Request changes (3) Ask a question"

- **Approve:** Move to the next section.
- **Request changes:** User describes what to modify. Update `$MEMORY_DIR/story-design.md` with the changes (edit inline). Re-present the updated section for re-approval.
- **Ask a question:** Answer from available context (analysis.md, discovery.md, ticket.md). If the question reveals a gap, update the design inline.

### Revision Tracking

After each revision round, increment the review counter:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh"
n1_increment_counter "$N1_HOME/memory/$ID/story-overview.md" "review_rounds"
```

## Optional Automated Design Review

Check if Codex is available:
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
CODEX_ENABLED=$(n1_config_val '.codex.enabled' "$CONFIG_FILE")
```

If Codex is enabled AND `n1_codex_available` returns 0:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
n1_codex_available
CODEX=$CODEX
CODEX_EFFORT=$(n1_codex_val 'effort')
CODEX_EFFORT="${CODEX_EFFORT:-medium}"
CODEX_MODEL_FLAG=""
CODEX_MODEL=$(n1_codex_val 'model')
[ -n "$CODEX_MODEL" ] && CODEX_MODEL_FLAG="--model $CODEX_MODEL"
```

Run Codex review of the design:
```bash
node "$CODEX" task --wait $CODEX_MODEL_FLAG --effort "$CODEX_EFFORT" --prompt-file "$MEMORY_DIR/story-design.md"
```

Present Codex findings to the user as advisory. User decides whether to address each finding.

## Completion Gate

After all sections are approved: "Design is approved. Ready to publish to the tracker and create subtask tickets?"

Wait for confirmation. If user wants more changes, loop back to the section they want to revise.

Update `story-overview.md`:
- Mark Review checkbox complete
- Update `step: review`

**Step result:** `outcome: "pass"`, `next_step: "publish"`
