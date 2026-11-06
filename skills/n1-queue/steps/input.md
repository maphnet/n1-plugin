# Input (plan paths: every entry except `--run`)

Resolves which tickets this run plans, then sets `QUEUE_ID` and `QUEUE_DIR`. It runs before § Unattended entry and intake, so a missing input stops before any claim, `mkdir` or tracker call. Exactly one input is required: a ticket list, `--tag <tag>` or `--story <ID>`. The default tag is never used.

1. **List items.** Every argument that is neither a flag nor a flag's operand is a list item. Flag operands: `--tag <tag>`, `--story <ID>`, `--run <queue-id>`, `--answer <ticket> <text>`, `--retry <ticket>`, `--status`/`--watch`/`--stop [<id>]`, `--schedule <trigger>`. An item that contains `'` is invalid without running anything. When there are list items, resolve them in one bash call, one single-quoted word per item:

```bash
source ~/.n1/preamble.sh
KEYS=""; BAD=""
for ITEM in '<ITEM_1>' '<ITEM_2>'; do
  case "$ITEM" in http://*|https://*) K=$(n1_extract_ticket_from_url "$ITEM" "$N1_HOME/config.json") || K="" ;; *) K="$ITEM" ;; esac
  if [[ "$K" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; then case " $KEYS " in *" $K "*) ;; *) KEYS="$KEYS $K" ;; esac
  else BAD="$BAD ${ITEM//[^A-Za-z0-9._:-]/_}"; fi
done
echo "KEYS=$KEYS"; echo "BAD=$BAD"
```

`KEYS` keeps the given order with duplicates dropped. Each `BAD` item (and each item containing `'`) is excluded with reason `invalid ticket key` (intake.md § List mode) and is never read or used in a path. `BAD` holds the sanitized form (every character outside `A-Za-z0-9._:-` replaced by `_`); write only that form to queue.md, never the raw item, because the runner parses `|` in any queue.md line. For an item containing `'`, write `(invalid item)`.

2. **Mixed input.** More than one input source (list items, `--tag`, `--story`; includes `--tag` with `--story`): print "Pass one input: a ticket list, --tag or --story." **STOP.**

3. **No input.** No list item, no `--tag` and no `--story`: under `--unattended` print "No input: pass ticket IDs, --tag <tag> or --story <ID>." **STOP.** Otherwise ask the user one free-text question with no selectable options: "Which tickets should this queue run? Reply with ticket IDs or tracker URLs (`<KEY-1> <KEY-2>`), `--tag <tag>` or `--story <ID>`." Apply items 1-2 to the reply once. Still no input: **STOP.**

4. **No valid key.** List items were given but `KEYS` is empty: print "No valid ticket keys in the list." **STOP.**

5. **Queue id and dir.** List mode (`mode: list`): `QUEUE_ID` is `list-` plus a checksum of the sorted keys, so the same list in any order gets the same id and the busy guard and `--run <id>` work as for a tag. Tag mode: the `--tag` value. Story mode: the story ID (a story URL is reduced to its key by the bash below). A tag, story ID or story URL that contains `'` is invalid: print "Invalid queue id: <id>." **STOP.** Otherwise run:

```bash
source ~/.n1/preamble.sh
KEYS='<KEYS printed by item 1, empty unless list mode>'; QUEUE_ID='<--tag value, story ID or story URL; empty in list mode>'
case "$QUEUE_ID" in http://*|https://*) QUEUE_ID=$(n1_extract_ticket_from_url "$QUEUE_ID" "$N1_HOME/config.json") || QUEUE_ID="" ;; esac
[ -n "$KEYS" ] && QUEUE_ID=$(printf 'list-%08x' "$(printf '%s\n' $KEYS | LC_ALL=C sort -u | cksum | cut -d' ' -f1)")
if [[ "$QUEUE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then mkdir -p "$N1_HOME/queue/$QUEUE_ID" && echo "QUEUE_ID=$QUEUE_ID QUEUE_DIR=$N1_HOME/queue/$QUEUE_ID"
else echo "Invalid queue id: $QUEUE_ID"; fi
```

`Invalid queue id: ...`: print it. **STOP.** Otherwise use the printed `QUEUE_ID` and `QUEUE_DIR` from here on.
