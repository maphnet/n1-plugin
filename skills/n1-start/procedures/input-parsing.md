# Procedure: Input Parsing

Input types: ticket ID, tracker URL, error-tracker URL (matches `urlPattern`), file path, brain dump, resume (existing memory).

**Moved flag:** user input containing `--investigate` → say "`--investigate` moved: run `/n1:n1-refine <ID> --investigate`." and STOP.

**Tracker URL normalization:**
```bash
source ~/.n1/preamble.sh
EXTRACTED=$(n1_extract_ticket_from_url "<user-input>" "$N1_HOME/config.json") && USER_INPUT="$EXTRACTED" || USER_INPUT="<user-input>"
```

**Detect input type:**
```bash
source ~/.n1/preamble.sh
n1_detect_input_type "$USER_INPUT" "$N1_HOME/config.json"
```
Returns: `ticket`, `error-tracker`, `file`, `braindump`.

**Error tracker URL:** extract last numeric segment after `/issues/` (e.g. `...sentry.io/issues/12345` → `12345`). Parse fail → brain-dump mode with warning. Provisional ID: `sentry-<issueId>`.
