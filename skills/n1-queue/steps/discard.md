# Discard (--discard <id>)

Removes a saved plan (`--plan`) that never started: its directory `$N1_HOME/queue/<id>/`. The plan is kept when it is missing, has started (a run id, a runner pid, a row past pending/held/skip, or a `## Runs` row), or is claimed by a scheduled run. There is no confirmation: the explicit id is the confirmation, and nothing has run. Works in headless sessions.

`QUEUE_ID` is the `--discard` argument. With none, print "--discard needs a queue id." **STOP.** It must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`; otherwise print "Invalid queue id: <id>." **STOP.** (SKILL.md § Input validates only `--run`, `--stop` and `--close` ids, and the id is interpolated into the snippet below.)

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
source "$N1_ROOT/lib/queue.sh"
n1_queue_plan_discard '<QUEUE_ID>' saved; echo "discard:rc=$?"
```

- `discard:rc=0`: print "Discarded saved plan <QUEUE_ID>." **STOP.**
- Any other rc: print "Not discarded: <QUEUE_ID> is missing, started or claimed. Use --close for a started queue." **STOP.**
