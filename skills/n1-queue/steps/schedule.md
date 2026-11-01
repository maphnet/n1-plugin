# Schedule (`--schedule <trigger>|list|remove`)

One scheduled automation per project (in the workspace manager) runs this queue on a trigger: `hourly`, `daily`, `weekdays`, `weekly`, a 5-field cron (`0 9 * * 1-5`) or an RRULE. Before each trigger the manager runs a bash precheck (no agent; a non-zero exit records a skipped run), then starts `/n1:n1-queue --tag <tag> --unattended` in the main checkout. Details: `<N1_ROOT>/references/architecture.md` § Scheduled queue runs (N1-226).

`<ARG>` is the `--schedule` argument; `<TAG>` is the queue tag (`--tag`, else `n1_queue_val tag`). Unless `<ARG>` is `list` or `remove`, it must match `^[A-Za-z0-9*][A-Za-z0-9 */,:=;_-]*$` (no quotes, no `$`); otherwise print "Invalid trigger: <ARG>." **STOP.**

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/queue.sh"
case '<ARG>' in
  list|remove) n1_queue_schedule '<ARG>' ;;
  *) if [ "$(n1_queue_val unattendedAutoStart)" != true ]; then
       echo "Scheduled runs are off. They plan and start with no Start prompt; to allow that, set queue.unattendedAutoStart to true in $N1_HOME/config.json, then re-run --schedule."
     else
       n1_queue_schedule create '<TAG>' '<ARG>' "$(n1_config_val '.tracker.type')" "$(n1_config_val '.tracker.mcp')" \
         "$(n1_config_val '.tracker.projectKey')" "$(n1_config_val '.tracker.statuses.todo')"
     fi ;;
esac
```

Print the output verbatim. After a successful create also print: "Re-run `/n1:n1-queue --schedule <trigger>` after changing the tag or tracker config, or after upgrading n1, to refresh the installed precheck. `/n1:n1-queue --schedule list` shows it and `/n1:n1-queue --schedule remove` deletes it." **STOP.**
