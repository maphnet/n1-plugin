# Procedure: Input Parsing

Parses and normalizes the user-supplied argument before Step 1.

## Input Parsing

The user provides one of:
- **Ticket ID** — matches the tracker prefix from config (e.g., `TRID-510`, `PROJ-42`)
- **Tracker URL** — a URL containing the tracker prefix and ticket number (e.g., `https://maphnet.youtrack.cloud/issue/H1-86/slug-text`)
- **Error tracker URL** — matches `urlPattern` from the error-tracker provider in `observability.providers` (e.g., `https://myorg.sentry.io/issues/12345`)
- **File path** — a path to a file containing requirements
- **Brain dump** — free-text description of what needs to be built
- **Resume** — ticket ID or slug where memory already exists

### Tracker URL normalization:

Before type detection, try to extract a ticket ID from URL inputs. This handles cases where the user pastes a tracker link instead of a bare ticket ID.

Run via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
EXTRACTED=$(n1_extract_ticket_from_url "<user-input>" "$N1_HOME/config.json") && USER_INPUT="$EXTRACTED" || USER_INPUT="<user-input>"
```

If extraction succeeds, use the extracted ticket ID as input for all subsequent steps. The original URL is discarded — the ticket ID is sufficient for tracker MCP lookups.

### Detect input type:

Run via Bash:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/validation.sh"
n1_detect_input_type "$USER_INPUT" "$N1_HOME/config.json"
```

Returns exactly one of: `ticket`, `error-tracker`, `file`, `braindump`.

### Error tracker URL parsing:

When error tracker mode is detected, extract the issue ID from the URL:
- Match the last numeric segment after `/issues/` in the URL path (e.g., `https://myorg.sentry.io/issues/12345` → `12345`)
- If parsing fails (no numeric ID found), fall back to **Brain dump mode** with the URL as text content and warn: "Could not parse issue ID from URL — treating as brain dump."
- Store the original URL for later use in ticket.md and tracker ticket creation.
- The provisional memory ID is `sentry-<issueId>` (e.g., `sentry-12345`). The `sentry-` prefix avoids collision with numeric ticket IDs.

### Branch flag detection

Check if the input contains `--branch`:

```bash
BRANCH_FLAG=false
case "$RAW_INPUT" in
    *--branch*) BRANCH_FLAG=true ;;
esac
```

The `--branch` flag forces branch isolation (no worktree) for this run. Strip `--branch` from the input before passing to ticket/brain-dump parsing.

### Investigate flag detection

Check if the input contains `--investigate`:

```bash
INVESTIGATE_FLAG=false
case "$RAW_INPUT" in
    *--investigate*) INVESTIGATE_FLAG=true ;;
esac
```

The `--investigate` flag starts an interactive investigation. It forces the `investigation` pipeline type (equivalent to `--type investigation`, bypassing title/tag detection) and additionally:

- Forces `BRAINSTORM_MODE=interactive` for this run, overriding `autonomy.brainstorm` from config (the brainstorm step reads `investigate_interactive` from overview.md frontmatter — see steps/brainstorm.md).
- In brain-dump mode, defers tracker ticket creation until the investigation deliverable is complete (see steps/ticket.md and steps/investigation-deliverable.md).

Strip `--investigate` from the input before passing to ticket/brain-dump parsing. Pass `INVESTIGATE_FLAG` in context to the ticket step.
