# Procedure: Input Parsing

Input types: ticket ID, tracker URL, error-tracker URL (matches `urlPattern`), file path, brain dump, resume (existing memory).

**Moved flag:** user input containing `--investigate` → say "`--investigate` moved: run `/n1:n1-refine <ID> --investigate`." and STOP.

**Type flag + URL normalization:** split `--type <name>` off first; remember `TYPE_OVERRIDE` (empty if none) for `steps/ticket.md`, and use the printed `USER_INPUT` below.
```bash
source ~/.n1/preamble.sh
RAW="<user-input>"; TYPE_OVERRIDE=$(n1_parse_type_arg "$RAW") || TYPE_OVERRIDE=""; USER_INPUT=$(n1_strip_type_arg "$RAW")
EXTRACTED=$(n1_extract_ticket_from_url "$USER_INPUT" "$N1_HOME/config.json") && USER_INPUT="$EXTRACTED"
echo "TYPE_OVERRIDE=$TYPE_OVERRIDE USER_INPUT=$USER_INPUT"
```

**Detect input type:**
```bash
source ~/.n1/preamble.sh
n1_detect_input_type "$USER_INPUT" "$N1_HOME/config.json"
```
Returns: `ticket`, `error-tracker`, `file`, `braindump`.

**Error tracker URL:** extract last numeric segment after `/issues/` (e.g. `...sentry.io/issues/12345` → `12345`). Parse fail → brain-dump mode with warning. Provisional ID: `sentry-<issueId>`.
