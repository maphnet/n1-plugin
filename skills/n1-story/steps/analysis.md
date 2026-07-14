# Step 2: Analysis (Multi-Repo)

## Repo Validation

Read the `repos` list from `story-overview.md` frontmatter. For each repo path:
```bash
expanded="${repo_path/#\~/$HOME}"
if [ ! -d "$expanded/.git" ]; then
    echo "Warning: $repo_path is not a git repository, excluding from analysis"
fi
```

Build a validated `$VALID_REPOS` array. The current working directory is always included as the first entry.

## Sequential Per-Repo Analysis

For each repo in `$VALID_REPOS`, spawn **solution-architect**:

- **Agent type:** `n1:solution-architect`
- **Model:** resolve via `n1_resolve_model "solution-architect"`
- **Prompt:**
  - "You are analyzing repo `<repo-path>` as part of a multi-repo story analysis."
  - "The feature being planned:" — provide path to `$MEMORY_DIR/ticket.md` for the agent to Read
  - "Focus your analysis on components relevant to this feature."
  - "Tag each section with a confidence level: `<!-- confidence: confident -->`, `<!-- confidence: uncertain -->`, or `<!-- confidence: unknown -->`"
  - "Use the following output structure:"

  ```markdown
  ## Repo: <name> (<path>)
  ### Architecture
  <!-- confidence: confident|uncertain|unknown -->
  
  ### Relevant Components
  <!-- confidence: confident|uncertain|unknown -->
  
  ### Integration Points
  <!-- confidence: confident|uncertain|unknown -->
  
  ### Risks & Constraints
  <!-- confidence: confident|uncertain|unknown -->
  ```

  - Research standards directive: "Follow the research rubric in `${CLAUDE_PLUGIN_ROOT}/agents/research-standards.md`"
  - "Write your output to `$MEMORY_DIR/analysis-<repo-name>.md`"

Each agent runs in the context of its target repo directory.

## Cross-Repo Synthesis

After all per-repo analyses complete, spawn solution-architect one final time:

- **Prompt:**
  - "Read the following per-repo analysis files and synthesize a Cross-Repo Concerns section:"
  - List paths to all `$MEMORY_DIR/analysis-<repo-name>.md` files
  - "Identify: shared interfaces (APIs, events, schemas), data flow between repos, deployment dependencies, and potential conflicts."
  - "Tag confidence levels on the cross-repo section."

## Assemble Final `analysis.md`

Concatenate all per-repo analysis sections and the cross-repo synthesis into a single `$MEMORY_DIR/analysis.md`:

```markdown
# Story Analysis

<per-repo sections in order>

## Cross-Repo Concerns
<synthesis output>
```

Clean up temporary per-repo files (`analysis-<repo-name>.md`).

Update `story-overview.md`:
- Mark Analysis checkbox complete
- Update `step: analysis`

**Step result:** `outcome: "pass"`, `next_step: "discovery"`
