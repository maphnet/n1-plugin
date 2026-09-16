---
name: n1-init
description: "Set up N1 for a project. Creates externalized state at ~/.n1/<project>/, config.json, and enriches CLAUDE.md with project conventions."
model: sonnet
effort: low
---

# N1 Project Setup

## Overview

Initialize N1 for the current project. This creates the externalized N1 state directory at `~/.n1/<project-name>/`, generates `config.json` with tracker and git settings, configures worktree setup, and optionally enriches CLAUDE.md with detected project conventions. N1_HOME is auto-derived at runtime from the repo name — no git config needed.

**Announce at start:** "I'm using the n1-init skill to set up N1 for this project."

**UX rules:**
- Do NOT show step numbers to the user — they are internal structure only.
- All choice questions MUST offer numbered options (e.g., `1 — Yes / 2 — No`) so the user can answer with just a number.

## N1_HOME Resolution

Resolve N1_HOME at the start. Use this preamble in every bash block that needs `$N1_ROOT`:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
```

## Steps

Execute steps in order. Read each step file and follow its instructions before proceeding to the next.

1. **Prerequisites** — detect existing config, handle migration, targeted upgrade
   Read `<N1_ROOT>/skills/n1-init/steps/01-prerequisites.md`

2. **Analyze Repository** — detect stack, worktree setup, enrich CLAUDE.md, host checks
   Read `<N1_ROOT>/skills/n1-init/steps/02-analyze-repo.md`

3. **Tracker Setup** — Jira/YouTrack/None, KB configuration, assign-to-creator
   Read `<N1_ROOT>/skills/n1-init/steps/03-tracker.md`

4. **Git Configuration** — default branch, branch pattern, PR mode
   Read `<N1_ROOT>/skills/n1-init/steps/04-git-config.md`

5. **Ticket Tagging** — service name tagging for created tickets
   Read `<N1_ROOT>/skills/n1-init/steps/05-ticket-tagging.md`

6. **Observability** — MCP server discovery, provider configuration
   Read `<N1_ROOT>/skills/n1-init/steps/06-observability.md`

7. **Estimation** — complexity estimation and delivery time
   Read `<N1_ROOT>/skills/n1-init/steps/07-estimation.md`

8. **Local Testing** — mode selection, startup detection
   Read `<N1_ROOT>/skills/n1-init/steps/08-local-testing.md`

9. **Finish & Release** — finish work and release configuration
   Read `<N1_ROOT>/skills/n1-init/steps/09-finish-release.md`

10. **Quality & Pipeline Config** — autonomy, telemetry, analysis cache
    Read `<N1_ROOT>/skills/n1-init/steps/10-quality-config.md`

11. **Rules** — generate starter rules, convention migration
    Read `<N1_ROOT>/skills/n1-init/steps/11-rules.md`

12. **Agent Models** — per-agent model overrides (only when user requests)
    Read `<N1_ROOT>/skills/n1-init/steps/12-models.md`

13. **Write Config** — assemble config.json, create directory structure, configure .gitignore
    Read `<N1_ROOT>/skills/n1-init/steps/13-write-config.md`

14. **Related Projects** — cross-repo discovery and configuration
    Read `<N1_ROOT>/skills/n1-init/steps/14-related-projects.md`

15. **Confirm** — show summary, report next steps
    Read `<N1_ROOT>/skills/n1-init/steps/15-confirm.md`

## Escalation Defaults

Escalation values (`checkpoints`, `alwaysAskOn`) are code defaults in `lib/config.sh` -- n1-init does not write them. Existing configs with these keys still work (read if present).

## Expected Config Keys

The canonical set of top-level config keys. Used by step 01 for completeness checks and by targeted upgrade logic.

```
worktree, tracker, git, ticketTagging, observability, estimation,
localTesting, finishWork, release, telemetry, analysisCache, rules, autonomy, models
```
