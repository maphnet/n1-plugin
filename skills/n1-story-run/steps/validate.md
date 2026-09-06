# Validate

Runs before any subtask launches. Produces the plan table in `story.md`.

## 1. Fetch story
Call `mcp__<TRACKER_MCP>__<READ_OP>` for `STORY_ID` (Jira: include `cloudId`). Record `STORY_TITLE`, `STORY_DESC`, `STORY_STATUS`, `STORY_URL`.

## 2. Enumerate subtasks
- **Jira:** if `VERSION_MCP` is set call `mcp__<VERSION_MCP>__jcm_getIssue` and read `subtasks[]` (key, summary, status). Fallback: `mcp__<TRACKER_MCP>__searchJiraIssuesUsingJql` with `parent = <STORY_ID> ORDER BY created ASC`.
- **YouTrack:** call `mcp__<TRACKER_MCP>__<LINKS_OP>` for `STORY_ID`; keep links of type `subtask` where the story is the parent; targets are the subtasks.
For each subtask call `READ_OP` and record: `key`, `title`, `status`, `description`, `size` (estimation field when `estimation.writeToTracker` is true; else empty), `deps` = linked issue keys of type `is blocked by` / `depends on` that are also subtasks of this story.
Status classification: a status whose lowercase name is one of `done`, `closed`, `resolved`, `fixed`, `verified` -> `done-before-run`. Everything else -> `pending`.
If no `pending` subtasks: "All <N> subtasks of <STORY_ID> are already done." **STOP.**

## 3. Map subtasks to repos
For each `pending` subtask:
```bash
SERVICE=$(n1_story_parse_service "$TITLE")
if [ -n "$SERVICE" ]; then
  if HIT=$(n1_story_find_repo "$SERVICE"); then CFG_PATH=${HIT%%$'\t'*}; REPO=${HIT#*$'\t'}; N1_HOME_SUB=$(dirname "$CFG_PATH"); else CFG_PATH=""; REPO=""; fi
else
  MY_SERVICE=$(n1_config_val '.ticketTagging.service')
  if [ -z "$MY_SERVICE" ]; then CFG_PATH="$N1_HOME/config.json"; N1_HOME_SUB="$N1_HOME"; REPO=$(n1_config_val '.repoPath'); [ -z "$REPO" ] && REPO=$(git rev-parse --show-toplevel); else CFG_PATH=""; REPO=""; fi
fi
```
- Matched config but empty `REPO` -> AskUserQuestion: "Config for service `<SERVICE>` (<CFG_PATH>) has no `repoPath`. Enter the absolute path of that repo's main checkout." Validate with `git -C "<path>" rev-parse --show-toplevel`; then backfill: `jq --arg p "<path>" '.repoPath=$p' "$CFG_PATH" > tmp && mv tmp "$CFG_PATH"`.
- No matching config -> AskUserQuestion with options **Enter path**, **Skip this subtask** (Status `skip`, reason "no repo"), **Cancel**.
- Tracker consistency: for each `CFG_PATH`, `jq -r '.tracker.type,.tracker.mcp'` must equal the story config's values; otherwise list mismatches and **STOP**.
- Worktree warning: if `jq -r '.worktree.mode' "$CFG_PATH"` is not `worktree`, warn "<SERVICE> uses branch mode -- unattended runs on a shared checkout are unsafe." Soft gate (AskUserQuestion: Continue / Cancel).

## 4. Derive order
Build `EDGES` (lines `A>B`, A before B):
1. **Story description:** if `STORY_DESC` contains a numbered list where items include subtask keys, add edges between consecutive listed keys.
2. **Tracker links:** for each subtask with `deps`, add `<dep>><key>`.
3. **Gap fill:** if after 1-2 the graph leaves any pending subtask with neither predecessor nor successor AND there are >= 2 pending subtasks, spawn `solution-architect` (model `n1_resolve_model solution-architect standard`) with all subtask keys/titles/services/descriptions and ask only for: `DEPENDENCIES:` lines of the form `A>B: <reason>`, plus `FLAGS:` lines `KEY: <security|public-api|schema-migration|contract>` when a subtask's output is consumed by another subtask in a different service (`contract`) or touches auth/secrets (`security`), external API (`public-api`), DB schema (`schema-migration`). Parse both blocks; add edges; keep reasons.
```bash
ORDER=$(n1_story_toposort "$PENDING_KEYS_CSV" "$EDGES") || { echo "Dependency cycle: $(n1_story_toposort "$PENDING_KEYS_CSV" "$EDGES" 2>&1 >/dev/null)"; }
```
On cycle -> present the cycle and AskUserQuestion: **Drop tracker edges and use story order**, **Cancel**.

## 5. Choose models
For each pending subtask: if `size` empty, classify XS-XL from `description` using the tier table in `${CLAUDE_PLUGIN_ROOT}/skills/n1-start/steps/estimation.md` (read that file's step 3 table; classify inline, no agent). Then:
```bash
MODEL=$(n1_story_pick_model "$SIZE" "$FLAGS_CSV")
```
Reason string: `size <SIZE>` plus `; flags: <flags>` when any.

## 6. Preview gate
Print:
```
## Story <STORY_ID>: <STORY_TITLE>
| # | Subtask | Title | Service | Repo | Size | Model | Reason |
|---|---------|-------|---------|------|------|-------|--------|
| 1 | ... |
Done before run: <keys or none>   Skipped: <keys or none>
```
If `DRY_RUN`: print "Dry run -- nothing launched." **STOP** (do not write story.md).
AskUserQuestion options: **Start**, **Reorder / edit** (free text -> apply, re-print, ask again), **Change models** (free text `KEY=opus|sonnet` -> apply, re-print), **Cancel** (STOP).

## 7. Persist plan
Write `$STORY_MEM/story.md`:
```markdown
---
story_id: <STORY_ID>
step: execute
current_index: 0
started: <date -u +%Y-%m-%dT%H:%M:%SZ>
---
# Story <STORY_ID>: <STORY_TITLE>
<STORY_URL>

## Plan
| # | Subtask | Title | Service | Repo | N1 Home | Size | Model | Status | Reason |
|---|---------|-------|---------|------|---------|------|-------|--------|--------|
| 1 | <KEY> | <title> | <service> | <repo> | <n1 home dir> | <size> | <model> | pending | <reason> |
...
| - | <KEY> | <title> | <service> | | | | | done-before-run | already <status> |

## Decision Ledger
| Step | Decision | Chosen | Reason |
|------|----------|--------|--------|
| validate | order | <sequence> | <sources used: description/links/architect> |
| validate | model <KEY> | <model> | <reason> |

## Runs
| Subtask | Started | Exit | Outcome | PR | Merged |
|---------|---------|------|---------|----|--------|

## Escalations
```
