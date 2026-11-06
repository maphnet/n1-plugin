# Intake

Builds the candidate list for the queue. Three modes: tag (search tracker), story (subtasks of a parent) or list (ticket keys the user named, `steps/input.md`).

**Key validation.** Before any step below uses a candidate's `<KEY>` in a path (`$N1_HOME/memory/<KEY>/`, later `<QUEUE_DIR>/desc/<KEY>.txt`) or as `SELF_ID`, check it against `^[A-Z][A-Z0-9_]*-[0-9]+$` (SEC-L4). A key that doesn't match — a malformed tracker response, never a real ticket ID — is excluded with reason `invalid ticket key`; skip its `READ_OP` call and every later step for it.

## Tag mode

Search via `mcp__<TRACKER_MCP>__<SEARCH_OP>`:
- **YouTrack:** query `project: {PREFIX} tag: {<tag>} State: {<TODO_STATUS>}`, max results `n1_queue_val maxTickets`.
- **Jira:** JQL `project = <PROJECT_KEY> AND labels = "<tag>" AND status = "<TODO_STATUS>"`, maxResults `n1_queue_val maxTickets`. Include `cloudId` when set.

**Already-run check.** Before reading each result, check whether a previous queue run already handled it and its tag release was not confirmed (a stale tag). A ticket whose tag was released and later re-added by a human passes this check (explicit re-queue):
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
if RUN=$(n1_queue_already_run "$N1_HOME/memory/<KEY>/overview.md"); then echo "EXCLUDE run:$RUN"; else echo KEEP; fi
```
`EXCLUDE` -> excluded with reason `already run: <run> (tag not released; /n1:n1-queue --status releases it)`; skip its `READ_OP` call.

For each remaining result, call `mcp__<TRACKER_MCP>__<READ_OP>` to get `key`, `title`, `description`, `status`, `size` (estimation field if available). Before those calls, run one bash call that clears and marks every remaining result. Its keys already passed § Key validation. Repeat the last two lines once per key. The capture hook (`hooks/desc-capture.sh`) then writes each fetched title and description to `<QUEUE_DIR>/desc/<KEY>.title`/`.txt` for § Description quality and preview.md § Plan-Resolve 1's Snapshot. Never write those files yourself (NP-203 SEC-1). The hook consumes a key's mark on any read of it, even a failed one, so re-run that key's two lines before retrying its read:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
rm -f "<QUEUE_DIR>/desc/<KEY>.title" "<QUEUE_DIR>/desc/<KEY>.txt"
n1_desc_mark queue "<KEY>" "<QUEUE_ID>" || echo "MARK-FAILED <KEY>"
```

Repo and N1 Home for all candidates: current repo root (`git rev-parse --show-toplevel`) and `$N1_HOME`.

## Story mode

Call `mcp__<TRACKER_MCP>__<READ_OP>` for the story ID. Record `STORY_TITLE`.

Enumerate subtasks (same logic as tag mode but via parent link):
- **Jira:** call `mcp__<TRACKER_MCP>__<SEARCH_OP>` with JQL `parent = <STORY_ID> ORDER BY created ASC`. Include `cloudId`.
- **YouTrack:** call `mcp__<TRACKER_MCP>__<LINKS_OP>` for the story ID; keep links of type `subtask` where the story is the parent; targets are the subtasks. Call `READ_OP` on each.
- **Search/links error or unparseable result**: report the error and **STOP** (not zero subtasks).
- **Zero subtasks** (parsed empty result, any status): print "no subtasks — run /n1:n1-start <STORY_ID>" and **STOP** (no queue is built).

Status classification: a status whose lowercase name is one of `done`, `closed`, `resolved`, `fixed`, `verified` -> `done-before-run`. Everything else -> candidate.

**Epic expansion (Jira only).** When the tracker is Jira and the `READ_OP` call above returned issue type `Epic` for the story ID, expand every child, including those just classified `done-before-run` (a Done-class child can still hold an open Sub-task), before any later step uses them: a child with Sub-tasks queued as a row would stop at its own Headless Guard. Call each such child `<STORY_KEY>` (any issue type) and take them in enumeration order (created ASC):
1. Apply § Key validation to `<STORY_KEY>` before the search; an invalid key is excluded with reason `invalid ticket key` and never searched.
2. Call `mcp__<TRACKER_MCP>__<SEARCH_OP>` with JQL `parent = <STORY_KEY> ORDER BY created ASC`. Include `cloudId`. A search error or unparseable result for any child: report the error and **STOP** the whole intake (no partial plan).
3. Zero hits: the child's own status decides: candidate with Reason `epic child`, or `done-before-run` if Done-class.
4. Hits: apply § Key validation and the status classification above to each Sub-task, in result order. Non-done Sub-tasks replace the child as candidates, Reason `epic subtask of <STORY_KEY>`; done ones are excluded `done-before-run`. The child's own status is ignored here. When no Sub-task is left, exclude the child with reason `done-before-run (all subtasks done)`.

Depth is fixed at Epic > Story > Sub-task: never search a Sub-task for children. Every child is searched once whatever its type, so a child Epic expands like a Story. Record each child's title from the enumeration result as `<CHILD_TITLE>` for preview.md's Hierarchy block, with `|` and newlines replaced by a space. YouTrack has no Epic path here: its story mode is unchanged and the children are the rows. Any other root type (Story, Task, Bug) skips this paragraph.

For each candidate in story mode:
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
SERVICE=$(n1_story_parse_service "$TITLE")
if [ -n "$SERVICE" ]; then
  if HIT=$(n1_story_find_repo "$SERVICE"); then CFG_PATH=${HIT%%$'\t'*}; REPO=${HIT#*$'\t'}; N1_HOME_SUB=$(dirname "$CFG_PATH"); else CFG_PATH=""; REPO=""; fi
else
  MY_SERVICE=$(n1_config_val '.ticketTagging.service')
  if [ -z "$MY_SERVICE" ]; then CFG_PATH="$N1_HOME/config.json"; N1_HOME_SUB="$N1_HOME"; REPO=$(n1_config_val '.repoPath'); [ -z "$REPO" ] && REPO=$(git rev-parse --show-toplevel); else CFG_PATH=""; REPO=""; fi
fi
```
- No matching config -> ask the user: **Enter path**, **Skip** (Status `skip`, reason "no repo"), **Cancel**. `--unattended`: Skip without asking.
- Matched config but empty `REPO` -> ask for path, validate, backfill. `--unattended`: Skip (Status `skip`, reason "no repo") without asking.

## List mode

`KEYS` and `BAD` come from `<N1_ROOT>/skills/n1-queue/steps/input.md`. Each `BAD` item is excluded with reason `invalid ticket key`; every key in `KEYS` already passed § Key validation. No search, no `maxTickets` cap and no already-run check (a list run never releases a tag, so `n1_queue_already_run` would exclude every re-listed ticket). Run § Tag mode's clear-and-mark bash call for every key in `KEYS`, then call `mcp__<TRACKER_MCP>__<READ_OP>` for each key as in § Tag mode. A key the tracker reports as not found or not accessible (a typo or another project) is excluded with reason `not found` and its later steps are skipped; any other read error follows Error Recovery. Classify each status as in § Story mode: done-class -> excluded `done-before-run`; every other status -> candidate with Reason `list`. Repo and N1 Home: as in § Tag mode.

## Story check (tag and list mode)

A tagged or listed story is never expanded into the queue; the user runs it explicitly in story mode. Exclusion reason: `story: run with --story <ID>`.
- **Jira:** subtasks are not issue links. If the candidate's type (from `READ_OP`) is `Story` or `Epic`, search JQL `parent = <KEY> AND statusCategory != Done`, maxResults 1. Any hit -> exclude.
- **YouTrack:** call `mcp__<TRACKER_MCP>__<LINKS_OP>` (skip when `LINKS_OP` is empty). If the candidate is the parent of any `subtask` link whose target is not done -> exclude.

## Blocker check

For each candidate follow `<N1_ROOT>/references/blocker-check.md` § Check with `ID=<KEY>`, `CALLER=queue` (run its Gate once per intake). With `SKIP_REASON=not-configured` (the config predates the `getIssueLinks` operation), skip link checks, rely on the description grep, and say so in the preview. With `SKIP_REASON=error: <msg>`, note `blocker check skipped for <KEY> (<msg>)` in the preview and do not exclude on links. A candidate with any `OPEN_BLOCKERS` -> excluded with reason `blocked by <ID>`, except in the same-plan case (N1-64). If the only open blocker is itself a candidate of this plan, keep the candidate and prefix its Reason with `blocked_on <ID> · `. run.md § Write plan gives it Status `held`, and the runner launches it only after the user merges the blocker's PR (`n1_queue_held_sweep`). Two candidates that block each other (a cycle) are both excluded with reason `blocked by <ID> (cycle)`.

Additionally grep the description: a line matching `(after|depends|blocked|requires|needs).*<PREFIX>-[0-9]+` (case-insensitive) naming a ticket that is not done -> excluded with reason `blocked by <ID>`. The same-plan `held` exception above applies only to the tracker-link check; a description-grep blocker is always excluded outright, even when the named ticket is itself a candidate of this plan.

Excluded tickets are left for a later run (no toposort). Before § Output, a held candidate whose blocker was excluded by any later check is excluded too, with reason `blocked by <ID>`.

## Description quality

For each remaining candidate, grade the description with the product-analyst tiers (`<N1_ROOT>/agents/product-analyst.md` § Description Quality Assessment, table C): Empty, Skeletal, Weak, Adequate. A description that already carries `*Briefed by N1 (queue plan)*`, `*Structured by N1*`, `*Restructured by N1*`, `*Refined by N1*` or `Normalized by N1` (with or without `*` or `_` emphasis), or a ticket whose fetched comments carry a qualifying `Refined by N1` comment block (`<N1_ROOT>/agents/product-analyst.md` § Refined block rule, qualifier only; no `planned_at` check at plan time), counts as Adequate here, so it is never briefed twice. For an Empty candidate whose fetch returned no comments, read its comments once before the exclusion below and apply the same qualifier. Keep the tier with the candidate for preview.md § Plan-Resolve 1. Length alone never excludes.

Exclude only a candidate with nothing to work from: an Empty description and a vague title. The capture hook wrote each fetched title to `<QUEUE_DIR>/desc/<KEY>.title` (§ Tag mode). Story mode reads no issue per candidate, so for an Empty candidate without that file, run § Tag mode's mark bash call for it and call `READ_OP` for it first. Then:

```bash
source ~/.n1/preamble.sh
if [ ! -f "<QUEUE_DIR>/desc/<KEY>.title" ]; then echo MISSING
elif n1_title_vague "<QUEUE_DIR>/desc/<KEY>.title"; then echo VAGUE; else echo OK; fi
```

`VAGUE`: exclude with reason `no usable content: empty description, vague title`. `OK` or `MISSING` (the capture did not run): keep; preview briefs it.

## Duplicate check

For each remaining candidate, follow `<N1_ROOT>/references/duplicate-check.md` § Check with `CONTEXT=queue`, `TEXT` = candidate title + description, `SELF_ID=<KEY>`, and `OVERVIEW` empty. This pass only informs. Matches annotate the candidate's Reason (e.g. `tag match · possible duplicate: <ID>`), and nothing is excluded, prompted, or linked here. Keep each flagged candidate's `MATCHES` rows and the Gate's `LINK_OP`: the preview resolves them interactively (`CONTEXT=queue-plan`), and queue children skip the check entirely. The blocker check above is independent and unchanged.

## Model per ticket

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
MODEL=$(n1_story_pick_model "$SIZE")
```

If no size field, default to `sonnet`.

## Output

Build two lists:
- **Candidates**: `#`, `Ticket`, `Title`, `Repo`, `N1 Home`, `Model`, `Reason` (`tag match` for tag-mode candidates found via the tag search; `story subtask` for story-mode candidates found via subtask enumeration; `epic subtask of <STORY_KEY>` and `epic child` for Epic-mode candidates, § Story mode Epic expansion; `list` for list-mode candidates)
- **Excluded**: `Ticket`, `Reason` (already run, blocked, story, no usable content, skip, done-before-run, invalid ticket key, not found)

If no candidates: "No actionable tickets found." **STOP.**
