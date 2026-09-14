<!-- Purpose: Configure local end-to-end testing mode, startup detection, and teardown. -->

## Local Testing Configuration

Ask whether N1 should run local end-to-end tests after implementation and review, before creating a PR. **Default is No.**

```
Enable local testing?
After implementation + review, N1 can start your app locally and exercise the changed flows before creating a PR.
Requires the app to be startable from the command line.
1 — Yes
2 — No (default)
```

**If 2 (No) or default:**
```json
{
  "localTesting": {
    "enabled": false
  }
}
```

**If 1 (Yes):**

Select the testing mode:
```
How should N1 test this project locally?
1 -- Live: start infrastructure + app, run tests against live endpoints (services with Docker Compose, local dev servers)
2 -- Test: run test suite only, no infrastructure startup (libraries, CLIs, SDKs)
3 -- Smoke: skip pre-merge testing; run post-deploy verification in n1-finish (cloud-native services that cannot run locally)
```

**Mode suggestion heuristic:** Before presenting, check the project:
- If Startup Detection (below) would find a match (docker-compose, Makefile with run targets, package.json with dev/start, manage.py, Procfile) -> suggest `1 -- Live (Recommended)` with reason: "Detected `<file>` -- this project appears locally runnable."
- If `finishWork.deployWatch.enabled` is `true` in config AND no startup mechanism detected -> suggest `3 -- Smoke (Recommended)` with reason: "No local startup detected but deploy watch is configured -- smoke testing after deploy may be appropriate."
- Otherwise -> suggest `2 -- Test (Recommended)` with reason: "No local startup mechanism detected."

Write the selected mode:
```json
{
  "localTesting": {
    "enabled": true,
    "mode": "<live|test|smoke>",
    "maxFixAttempts": 3
  }
}
```

**If mode is `"live"` or `"test"`:** run the **Startup Detection** flow below. (For `"test"` mode, startCommand is optional but may still be useful.)
**If mode is `"smoke"`:** skip Startup Detection. Optionally ask for smoke config:
```
Optional: configure smoke verification for post-deploy testing.
1 -- Skip (configure later)
2 -- Enter smoke endpoint URL
```
- **1:** leave `smokeEndpoint` absent.
- **2:** prompt for URL, write to `localTesting.smokeEndpoint`.

### Startup Detection Heuristics

Check the project root for the following files in priority order:

| Priority | File Pattern | Suggested startCommand | Notes |
|----------|-------------|----------------------|-------|
| 1 | `docker-compose.yml`, `docker-compose.yaml`, or `compose.yml` | `docker compose up -d` | Most deterministic |
| 2 | `Makefile` with targets matching `^(up\|run\|serve\|start\|dev):` | `make <first matching target>` | Simple target grep |
| 3 | `package.json` with `dev` or `start` in `scripts` | `npm run dev` (prefer `dev` over `start`) | Check `dev` first |
| 4 | `manage.py` in project root | `python manage.py runserver` | Django convention |
| 5 | `Procfile` | Command from `web:` line, or `heroku local` | Extract after `web:` prefix |

Use the **highest-priority match only**. When multiple files are detected, mention the others for user awareness.

**If at least one file is detected**, present:
```
Detected <file> in project root.
Suggested start command: <command>
(Also detected: <other files>, if any)

1 — Accept
2 — Customize (enter your own command)
3 — Skip
```

- **1 (Accept):** Write suggested command to `localTesting.startCommand` in config.
- **2 (Customize):** Prompt: "Enter your start command:". Write user's input to `localTesting.startCommand`.
- **3 (Skip):** Leave `startCommand` absent.

**If no files are detected:**
```
No startup mechanism detected. You can configure `localTesting.startCommand` manually later.
```
Leave `startCommand` absent.

**After startCommand is accepted or customized (not skipped)**, offer teardown:
```
Optional: enter a teardown command for cleanup (e.g., docker compose down -v):
1 — Enter teardown command
2 — Skip
```
- **1 (Enter):** Prompt: "Enter your teardown command:". Write to `localTesting.teardownCommand`.
- **2 (Skip):** Leave `teardownCommand` absent.

### On reconfiguration (n1-init re-run):

If `localTesting` already exists in the current config, show current state and offer:
```
Current local testing configuration:
  Enabled: <true/false>
  Mode: <current mode or "(not set -- will infer from startCommand)">
  Start command: <current value or "(not set)">
  Teardown command: <current value or "(not set)">
  maxFixAttempts: <value>

1 — Keep current
2 — Enable
3 — Disable
4 — Change mode
5 — Reconfigure start/teardown commands
```
- **1** → leave unchanged.
- **2** → set `enabled: true`, `maxFixAttempts: 3`. If `mode` is absent, run the mode selection prompt from the fresh-setup flow. Then run the Startup Detection flow above.
- **3** → set `enabled: false`. Remove `maxFixAttempts`, `startCommand`, `teardownCommand`, and `mode` keys.
- **4** → run the mode selection prompt from the fresh-setup flow. Update `localTesting.mode`. If switching to/from `"smoke"`, adjust related keys accordingly.
- **5** → run the Startup Detection flow above (regardless of enabled state).

If `localTesting` is absent from the current config, run the fresh-setup flow above.
