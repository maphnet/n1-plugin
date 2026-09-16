# Procedure: Input Parsing

Input types: ticket ID, tracker URL, error-tracker URL (matches `urlPattern`), file path, brain dump, resume (existing memory).

**Tracker URL normalization:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
EXTRACTED=$(n1_extract_ticket_from_url "<user-input>" "$N1_HOME/config.json") && USER_INPUT="$EXTRACTED" || USER_INPUT="<user-input>"
```

**Detect input type:**
```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
n1_detect_input_type "$USER_INPUT" "$N1_HOME/config.json"
```
Returns: `ticket`, `error-tracker`, `file`, `braindump`.

**Error tracker URL:** extract last numeric segment after `/issues/` (e.g. `...sentry.io/issues/12345` → `12345`). Parse fail → brain-dump mode with warning. Provisional ID: `sentry-<issueId>`.

**Branch flag:**
```bash
BRANCH_FLAG=false
case "$RAW_INPUT" in *--branch*) BRANCH_FLAG=true ;; esac
```
Strip `--branch` from input before parsing.

**Investigate flag:**
```bash
INVESTIGATE_FLAG=false
case "$RAW_INPUT" in *--investigate*) INVESTIGATE_FLAG=true ;; esac
```
Forces `investigation` type + `BRAINSTORM_MODE=interactive`. Defers ticket creation in brain-dump mode. Strip `--investigate` before parsing.
