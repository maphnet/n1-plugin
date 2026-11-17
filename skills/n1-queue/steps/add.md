# Add (`--add [<id>] <ticket|url>...`)

Appends tickets to a running list or tag queue. Restarting the runner is not needed. The skill checks each ticket and stages it. The runner appends staged rows to the Plan on its next tick, within `queue.pollSeconds`. Existing rows are never re-planned. Never ask the user anything here: each refusal is one line, and this step is safe in headless runs.

## 1. Operands

Operands are the tokens after `--add`. The first operand is the queue id only when at least one more operand follows, it matches `^[A-Za-z0-9][A-Za-z0-9._-]*$` and `$N1_HOME/queue/<operand>/queue.md` exists (a story queue id looks like a ticket key, so a lone operand is always a ticket). All other operands are tickets. A token that contains `'` is prose and is never passed to bash. Resolve the other operands in one bash call, one single-quoted word per operand (candidate operands only: the first one is dropped from the list when it is the queue id):

```bash
source ~/.n1/preamble.sh
KEYS=""; BAD=""
for ITEM in '<OPERAND_1>' '<OPERAND_2>'; do
  case "$ITEM" in http://*|https://*) K=$(n1_extract_ticket_from_url "$ITEM" "$N1_HOME/config.json") || K="" ;; *) K="$ITEM" ;; esac
  K="${K^^}"
  if [[ "$K" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; then case " $KEYS " in *" $K "*) ;; *) KEYS="$KEYS $K" ;; esac
  else BAD="$BAD ${ITEM//[^A-Za-z0-9._:-]/_}"; fi
done
echo "KEYS=$KEYS"; echo "BAD=$BAD"
```

`KEYS` keeps the given order with duplicates dropped. Each `BAD` item (sanitized form) is refused: "Invalid ticket id or unknown queue: <item>." With no `KEYS`, print "Usage: /n1:n1-queue --add [<id>] <ticket|url>..." **STOP.**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
n1_queue_active_ids "$N1_HOME"
```

Run this block only when no queue id was given:
- Exactly one id printed: `QUEUE_ID` is that id.
- None printed: "No running queue. Start one with /n1:n1-queue <tickets>." **STOP.**
- Several printed: "Several queues are running: <ids>. Name one: /n1:n1-queue --add <id> <ticket>..." **STOP.**

## 2. Gate

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
QUEUE_DIR="$N1_HOME/queue/<QUEUE_ID>"; QUEUE_FILE="$QUEUE_DIR/queue.md"
n1_queue_add_gate "$QUEUE_FILE"
```

On a non-zero exit, relay the line as is. The queue may be unknown, story mode, planned, done, halted (a stopped queue is halted), interrupted, closing, stopping or draining after a halt. **STOP.**

## 3. Intake (per ticket)

Apply the list-mode checks of `<N1_ROOT>/skills/n1-queue/steps/intake.md` to each ticket. Refuse a ticket with a one-line reason, and keep going with the next ticket:
- **Readable and open:** the ticket is read with the tracker read operation. A ticket that is not found, or has a done-class status, is refused (`not found`, `already done`).
- **Story check:** a Story or Epic is refused: `is a Story/Epic; run it with --story <ID>`.
- **Blocker check:** follow `<N1_ROOT>/references/blocker-check.md`. If there are no open blockers, Reason is empty. If there is exactly one open blocker and it has a Plan row in this queue, Reason is `blocked_on <ID> · ` (the row starts `held`). A blocker that has no Plan row in this queue is refused: `blocked by <ID> (not in queue)`. Two or more open blockers are refused: `blocked by <ID>, <ID> (more than one open blocker)`.
- **Description quality:** apply intake.md § Description quality (a `Refined by N1` block counts as Adequate). Poor is refused: `description quality Poor; run /n1:n1-refine <KEY> first`. No interactive repair.
- **Model, Repo and N1 Home:** as intake.md resolves them for this queue's mode. A Repo or N1 Home pair that no existing Plan row has is refused at staging.

Then run `<N1_ROOT>/skills/n1-queue/steps/preview.md` § Plan-Resolve step 1 (brief and description snapshot) for the accepted tickets only; it writes `desc/<KEY>.title|txt`. Its ` · repaired` and ` · briefed` Reason suffixes are not copied into the staged Reason cell; Reason holds only the `blocked_on <ID> · ` prefix or stays empty. Skip the rest of Plan-Resolve: step 2 (duplicates; the stage helper checks), step 3 (overlap order) and step 4 (stop-list pre-scan, which asks the user one question per flagged ticket and would break the never-ask rule). Pre-Decision stays empty, the default "ask at runtime" behavior: the child pauses on a security, architecture or public-API escalation, as today.

## 4. Stage

For each accepted ticket, use the file-write mechanism to write `<QUEUE_DIR>/add-<KEY>.tsv`. The file holds one line of 10 tab-separated fields: Title, Repo, N1 Home, Model, Reason, then Touches, Order, Pre-Decision, Desc Checksum (the helper computes it from `desc/<KEY>.*`) and Notes, all empty. Leave a field empty when it has no value. Never put a tab or newline inside a field, and never put free text inside a shell argument. Then run:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
QUEUE_DIR="$N1_HOME/queue/<QUEUE_ID>"; QUEUE_FILE="$QUEUE_DIR/queue.md"
for K in <KEY>...; do
    n1_queue_add_stage "$QUEUE_FILE" "$K" "$QUEUE_DIR/add-$K.tsv"
    rm -f "$QUEUE_DIR/add-$K.tsv"
done
```

The helper refuses the following, and stages nothing for that ticket:
- a key already in the Plan or `## Excluded`, in any status
- a key already being added
- a blocker outside the queue, or a blocker that is failed, escalated or skipped
- a foreign repo
- an invalid model

## 5. Report

Print one line per ticket: `queued` or the refusal reason. Then print: "Queued tickets join queue <QUEUE_ID> within queue.pollSeconds; no restart. Check with /n1:n1-queue --status <QUEUE_ID>. A row the runner refuses when it appends (a duplicate added at the same moment, or the queue finishing first) is listed there as `add refused`." **STOP.**

## Notes

- Added rows run after the rows that are already pending. They follow `max_concurrent` and the three-strikes halt. A `held` row starts when `n1_queue_held_sweep` releases it.
- The integration decision is never revisited. A queue recorded `integration: none` stays so, and its added rows stop at PR unless `autonomy.fullAuto` and `finishWork.mergeOnFinish` are both true. Merges stay gated by `n1_merge_authorized`.
- `## Schedule` is not rebuilt. An added row has no file-overlap ordering against rows in flight.
- In tag mode, an added ticket does not need to carry the queue tag.
- A late add can start work in a queue that is about to finish. A row staged after the runner's last tick is refused with `queue-finished`, and the ticket is never silently lost; add it to a new queue.
