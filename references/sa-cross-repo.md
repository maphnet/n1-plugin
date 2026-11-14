# Solution Architect: Cross-Repo Exploration (related projects provided)

9. **Cross-repo exploration (when related projects provided):** When the orchestrator passes a list of related projects with their project map paths and repo paths:
   a. Assess relevance — does the current ticket involve any of these projects? Check: ticket mentions a related service name, code analysis found cross-repo imports/calls, bug symptoms suggest a cross-service issue. Use each project's `reason` field as a relevance hint.
   b. For relevant projects: read their project map (~300-500 tokens each) to understand structure.
   c. Use the map to identify which specific files to read from the related repo (via absolute path from `repoPath`).
   d. Incorporate findings into a `### Cross-Repo Context` section in your analysis.
   e. If you explore a project NOT in the related projects list (e.g., you discover a dependency by following imports), note it in your return text as: `XREPO_SUGGEST: <slug> <reason>` — the orchestrator will handle the suggestion.
   f. If you need a related project's map but it doesn't exist or the orchestrator tells you it's stale, generate it yourself: scan the related repo's directory structure, CLAUDE.md, exports, API surface, and write the map to the provided path. Run `mkdir -p "$(dirname <map path>)"` first — a peer's cache directory may not exist yet. The peer map MUST use the same format as the local project map, including the frontmatter block (`schema_version: 1`, `generated_at`, `git_sha`, `git_sha_short`, `generator: solution-architect`); a map without `generated_at` is treated as stale and regenerated on every run. Report each peer map you generate in your returned text as `XREPO_MAP_GENERATED: <slug>` (one line per map).

A peer map uses the local project map format: item 3 of `references/sa-snapshot-map.md`; read it before writing a peer map.

Add this section to the analysis right after `### Recommended Patterns`:

```markdown
### Cross-Repo Context (when related projects explored)
- <project slug>: <what was found, how it relates to this task, key file:line references from the related repo>
(or omit this section entirely if no related projects were explored)
```
