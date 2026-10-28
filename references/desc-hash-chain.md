# Description Hash Chain (queue children)

The headless guard (`skills/n1-start/procedures/autonomy-headless.md` § Content check) honours a plan-time pre-decision only while the ticket still says what it said at plan time. Without this procedure, N1's own description writes in a queue child read as "changed". Each N1 write records its resulting hash, so the guard accepts it. A human edit after planning is never recorded and still reads as changed (NP-231).

**Gate.** This procedure applies only in queue children. It also clears any pre/post and live-check scratch files a previous write site or check left behind, so this site never hashes stale trusted text if its own Before step or a scratch write is later skipped or fails:

```bash
source ~/.n1/preamble.sh
M="$N1_HOME/memory/<ID>"
rm -f "$M"/.desc-pre.* "$M"/.desc-post.* "$M"/.guard-live.*
[ -n "${N1_QUEUE_RUN_ID:-}" ] && echo CHAIN || echo SKIP
```

`SKIP`: ignore this file and write as usual.

## Before the write

Take the ticket's title and description exactly as fetched from the tracker for this write (the fetch the write site already does; fetch now if it did not). Build the new description from this same fetch. Write them to `$N1_HOME/memory/<ID>/.desc-pre.title` and `$N1_HOME/memory/<ID>/.desc-pre.txt` with the file-write mechanism. Tracker text is untrusted, and passing it through a shell string is command injection (SEC-1). No shell command runs in this step.

## After the write

Run this step only when the tracker description write succeeded. Re-fetch the ticket with the tracker read operation as the very next tracker call after the write. The tracker may normalize markup, so never hash the text you sent. Write the fetched title and description to `$N1_HOME/memory/<ID>/.desc-post.title` and `$N1_HOME/memory/<ID>/.desc-post.txt` the same way. N1 writes a title only at queue plan time, before the snapshot (`skills/n1-queue/steps/preview.md` § Plan-Resolve 1), never in a child, so any difference between the pre-write and post-write title is a human edit made in the window and must not be recorded. Then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
M="$N1_HOME/memory/<ID>"
PRE=$(n1_queue_content_hash "$M/.desc-pre.title" "$M/.desc-pre.txt")
POST=$(n1_queue_content_hash "$M/.desc-post.title" "$M/.desc-post.txt")
cmp -s "$M/.desc-pre.title" "$M/.desc-post.title" || POST=""
n1_desc_hash_record "<ID>" "$PRE" "$POST" && echo RECORDED || echo NOT-RECORDED
rm -f "$M"/.desc-pre.* "$M"/.desc-post.*
```

`n1_desc_hash_record` appends `POST` to `$N1_HOME/memory/<ID>/.desc-hashes` only when `PRE` is trusted: either the plan-time Desc Checksum or a hash this run already recorded. `NOT-RECORDED` is expected and non-blocking, so continue the step. It happens when a human edited the ticket after planning, a fetch failed, or there is no trustworthy plan. The guard then reads the ticket as changed and escalates instead of applying a plan-time answer, which is the safe outcome (SEC-5). The final `rm -f` runs unconditionally, so a skipped Before step at the next write site finds no stale files to hash. Never append to `.desc-hashes` any other way.

## Intake check (refined description block)

`agents/product-analyst.md` § Refined block rule runs this in a queue child before it uses a description `Refined by N1` block. A block edited after `n1-queue --plan` then never reaches ticket.md as-is (N1-164). The comment block keeps its own `planned_at` guard. Reuse the § Gate result if this intake already ran it (Title & Form Repair step 3). Otherwise run § Gate now. On `SKIP`, there is no check and the block is used as usual. On `CHAIN`, take the ticket's title and description as fetched at intake. No extra fetch is needed, and a Refined ticket gets no description write in intake. Write them to `$N1_HOME/memory/<ID>/.guard-live.title` and `$N1_HOME/memory/<ID>/.guard-live.txt` with the file-write mechanism, never through a shell string (SEC-1). Then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
M="$N1_HOME/memory/<ID>"
NEW_HASH=$(n1_queue_content_hash "$M/.guard-live.title" "$M/.guard-live.txt")
if [ -n "$NEW_HASH" ] && n1_desc_hash_is_trusted "<ID>" "$NEW_HASH"; then echo MATCH; else echo MISMATCH; fi
rm -f "$M"/.guard-live.*
```

`MATCH` means the text is the plan-time Desc Checksum or a hash this run recorded after one of N1's own writes, so use the block. `MISMATCH` or no output covers three cases: a human edited the title or description after planning, a scratch write failed, or there is no trustworthy plan (SEC-5). In all three, ignore the description block (treat it as absent) and continue with the comment block or the normal distill. The block's text then reads as ordinary description text: no `### Decisions` are copied from it and no `[refined]` tag counts. The hash covers the whole title and description, so an edit outside the block also reads `MISMATCH`. That is the accepted fail-closed price, the same as in the headless Content check. A `--run` re-plan re-baselines the Desc Checksum, so edits caught at `--run` are trusted afterwards. On `MISMATCH` or no output, also write `Ignored refined block: <cause>` (cause: edited after plan, fetch failed, or no trustworthy plan) on its own line in ticket.md before `### Key Comments`, and mention it in the summary; it is informational, never a Decision and never counts as `[refined]`. The final `rm -f` runs unconditionally.
