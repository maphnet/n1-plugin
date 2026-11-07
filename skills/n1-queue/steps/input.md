# Input (plan paths: every entry except `--run`)

Resolves which tickets this run plans, then sets `QUEUE_ID` and `QUEUE_DIR`. It runs before § Unattended entry and intake, so a missing input stops before any claim, `mkdir` or tracker call. Exactly one input is required: a ticket list, `--tag <tag>`, `--story <ID>` or `--goal "<text>"`. The default tag is never used.

**Never infer the input (N1-440).** The only input sources are this call's arguments and the reply to item 3. Never pick a tag, story or ticket list from conversation context, memory, config, a schedule or an existing queue dir, and never reuse a queue dir because it looks current. No explicit input means item 3 asks, every time.

1. **Arguments.** Every argument that is neither a flag nor a flag's operand is a token. Flag operands: `--tag <tag>`, `--story <ID>`, `--goal "<text>"` (the quoted value, or the words up to the next flag; it is never a token and never reaches bash), `--run <queue-id>`, `--answer <ticket> <text>`, `--retry <ticket>`, `--status`/`--watch`/`--stop`/`--close [<id>]`, `--schedule <trigger>`. A token that contains `'` is prose and is never passed to bash. Resolve the other tokens in one bash call, one single-quoted word per token:

```bash
source ~/.n1/preamble.sh
KEYS=""; BAD=""; PROSE=""
for ITEM in '<ITEM_1>' '<ITEM_2>'; do
  case "$ITEM" in http://*|https://*) K=$(n1_extract_ticket_from_url "$ITEM" "$N1_HOME/config.json") || K="" ;; *) K="$ITEM" ;; esac
  if [[ "$K" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; then case " $KEYS " in *" $K "*) ;; *) KEYS="$KEYS $K" ;; esac
  elif [[ "$ITEM" =~ ^https?:// || "$ITEM" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]]; then BAD="$BAD ${ITEM//[^A-Za-z0-9._:-]/_}"
  else PROSE="$PROSE ${ITEM//[^A-Za-z0-9._:-]/_}"; fi
done
echo "KEYS=$KEYS"; echo "BAD=$BAD"; echo "PROSE=$PROSE"
```

`KEYS` keeps the given order with duplicates dropped. List items are `KEYS` plus `BAD`. A `BAD` item is a key-shaped token that is not a valid key (for example `n1-5`) or a URL that does not resolve to a key. It is excluded with reason `invalid ticket key` (intake.md § List mode) and is never read or used in a path. `BAD` holds the sanitized form (every character outside `A-Za-z0-9._:-` replaced by `_`); write only that form to queue.md, never the raw item, because the runner parses `|` in any queue.md line.

**Prose.** `PROSE` tokens and tokens containing `'` are a session instruction, not a ticket selector. Print `Session instruction (not a ticket selector): <the prose words as the user typed them>`. Apply it when it is a change the user could make in this session anyway (for example a config edit, done before preview.md § Plan-Resolve 3 reads `queue.maxConcurrent`), otherwise acknowledge it. Never use prose as a ticket key, tag, story ID, path or shell word, and never let it choose the input. `--unattended`: print the line and do not apply it.

2. **Mixed input.** More than one input source (list items, `--tag`, `--story`, `--goal`; includes `--tag` with `--story`): print "Pass one input: a ticket list, --tag, --story or --goal." **STOP.** Prose is not a list item, so `--tag <tag>` plus prose is tag mode. **Goal checks (N1-441)**, before any write: `--goal` with `--unattended`: print "Goal mode needs approval; pass ticket IDs, --tag or --story." **STOP.** `--goal` with no text, empty text, or a flag right after it (for example `--goal --dry-run`): print "Goal text is empty." **STOP.** Goal text that contains `'`: print "Invalid goal: remove the apostrophe (')." **STOP.** The goal text is ranking context only. Never use it as a token, tag, search-query term, path, plan-state value or queue.md value.

3. **No input.** No list item, no `--tag`, no `--story` and no `--goal` (prose alone counts as no input): under `--unattended` print "No input: pass ticket IDs, --tag <tag> or --story <ID>." **STOP.** Otherwise ask the user one free-text question with no selectable options: "Which tickets should this queue run? Reply with ticket IDs or tracker URLs (`<KEY-1> <KEY-2>`), `--tag <tag>`, `--story <ID>` or `--goal "<text>"`." Apply items 1-2 to the reply once. Still no input: **STOP.**

3b. **Goal mode.** With `--goal`: read and follow `<N1_ROOT>/skills/n1-queue/steps/goal.md`. It either STOPs or returns `KEYS` (the approved keys), `GOAL_REASONS` and `GOAL=goal`. Continue at item 4 in list mode (`MODE=list`, `SRC` = the approved keys).

4. **No valid key.** `KEYS` is empty and `BAD` is not: print "No valid ticket keys in the list." **STOP.**

5. **Queue id and dir.** The id base: list mode (`mode: list`) is `list-` plus an 8-hex checksum of the sorted keys (the same list in any order gives the same base); goal mode is `goal-` plus the same checksum of the approved keys and is saved as `mode: list` (the goal text never reaches the id, a path or plan state); tag mode is the `--tag` value; story mode is the story ID (a story URL is reduced to its key by the bash below). Every plan except `--unattended` gets its own id: `n1_queue_new_id` cuts the base to 40 characters, appends `-<UTC yyyymmddThhmmssZ>` (plus `-<random>` when that dir already exists) and creates the dir with an atomic `mkdir`, so two plans of the same input never share rows. `--unattended` keeps the base as the id, because a scheduled trigger's claim and resume are keyed on that dir (run.md § Unattended entry). The tag and story ID stay attributes in queue.md frontmatter (`tag`, `story_id`). A tag, story ID or story URL that contains `'` is invalid: print "Invalid queue id: <id>." **STOP.** Otherwise run, with `MODE` the input mode and `UNATTENDED` set to `yes` only under `--unattended`:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
KEYS='<KEYS printed by item 1 or approved in steps/goal.md, empty in tag and story mode>'; GOAL='<the literal word goal in goal mode, else empty; never the goal text>'; QUEUE_ID='<--tag value, story ID or story URL; empty in list mode>'; MODE='<list|tag|story>'; UNATTENDED='<yes or empty>'
case "$QUEUE_ID" in http://*|https://*) QUEUE_ID=$(n1_extract_ticket_from_url "$QUEUE_ID" "$N1_HOME/config.json") || QUEUE_ID="" ;; esac
[ -n "$KEYS" ] && QUEUE_ID=$(printf '%s-%08x' "${GOAL:-list}" "$(printf '%s\n' $KEYS | LC_ALL=C sort -u | cksum | cut -d' ' -f1)")
SRC="${KEYS:-$QUEUE_ID}"
if ! [[ "$QUEUE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then echo "Invalid queue id: $QUEUE_ID"
else
  if [ -n "$UNATTENDED" ]; then mkdir -p "$N1_HOME/queue/$QUEUE_ID" || QUEUE_ID=""
  else QUEUE_ID=$(n1_queue_new_id "$QUEUE_ID") || QUEUE_ID=""; fi
  if [ -z "$QUEUE_ID" ]; then echo "Invalid queue id: queue dir not created"
  else
    echo "QUEUE_ID=$QUEUE_ID QUEUE_DIR=$N1_HOME/queue/$QUEUE_ID"
    n1_queue_plan_state write "$QUEUE_ID" intake "$MODE" "$SRC" || echo "PLAN_STATE=off"
  fi
fi
```

`Invalid queue id: ...`: print it. **STOP.** `PLAN_STATE=off` (no usable session id): continue; only compaction recovery of this plan is lost. Otherwise use the printed `QUEUE_ID` and `QUEUE_DIR` from here on, and print the id so `--run <QUEUE_ID>` can be used later. The planning state (`n1_queue_plan_state`) is what the session restores after compaction; preview.md and run.md advance it with `n1_queue_plan_state step <preview|plan-resolve|saved>`.
