---
name: n1-telemetry-analyzer
description: "Analyze recent pipeline runs: per-run performance metrics (steps, agents, tokens, tools, durations), anomaly detection (slow steps, token-heavy agents, low cache efficiency, excessive fix cycles), and cross-run aggregations (averages, P90 by tier and step). Use when asked to analyze telemetry, review pipeline performance, spot patterns, or check run efficiency."
argument-hint: "[--last N] [--projects p1,p2] [--deep]"
model: sonnet
effort: medium
---

# N1 Telemetry Analyzer

**Announce at start:** "I'm using the n1-telemetry-analyzer skill to analyze recent pipeline runs."

All analysis is done by `scripts/telemetry_analyzer.py`. This skill only drives it and formats the output. Never compute metrics by hand.

## 1. Resolve paths and collect

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)
SCRIPT="$N1_ROOT/scripts/telemetry_analyzer.py"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT_DIR="$N1_HOME/reports"
mkdir -p "$REPORT_DIR"
```

If `N1_HOME` is empty or `~/.n1` does not exist, tell the user N1 is not configured and stop.

## 2. Run the analyzer

Parse the user's arguments (--last N, --projects, --deep) and pass them through.
Default: `--last 20`, no project filter, no --deep.

```bash
python3 "$SCRIPT" collect --n1-root "$(dirname "$N1_HOME")" --last N [--projects P1,P2] [--deep] --out "$REPORT_DIR/telemetry-$TIMESTAMP.json"
```

Capture stdout as JSON. If the script exits with an error or the JSON contains an `error` key, report the error to the user and stop.

## 3. Format and present

Parse the JSON output and present in this order:

### 3a. Summary table

One row per run, sorted by date descending:

| # | Ticket | Project | Tier | Duration | Tokens (in/out) | Tools | Agents | Cache% | Outcome | Anomalies |
|---|--------|---------|------|----------|-----------------|-------|--------|--------|---------|-----------|

Format rules:
- Duration: format as `Xm Ys` (e.g., `12m 34s`)
- Tokens: use K suffix (e.g., `150K/23K`)
- Cache%: percentage with 0 decimals
- Anomalies: count, or `-` if none

### 3b. Cross-run aggregation

Present the `aggregation` section:

**By tier:**

| Tier | Runs | Avg Duration | P90 Duration | Avg Tokens | P90 Tokens | Avg Cache% |
|------|------|-------------|-------------|-----------|-----------|-----------|

**By step:**

| Step | Avg Duration | P90 Duration | Avg Tokens | P90 Tokens |
|------|-------------|-------------|-----------|-----------|

### 3c. Anomalies

If any runs have anomalies, list them grouped by type:

**Slow steps (>5min):**
- `[ticket]` step `[name]`: Xs

**Token-heavy agents (>100K input):**
- `[ticket]` agent `[type]` in `[step]`: NK tokens

**Low cache efficiency (<50%):**
- `[ticket]`: X%

**Excessive fix cycles (>3):**
- `[ticket]`: N cycles

If no anomalies: "No anomalies detected across the analyzed runs."

### 3d. Bash command subtypes (--deep only)

If deep mode was used, show a summary table of Bash command distribution:

| Command | Total | Avg/Run |
|---------|-------|---------|

### 3e. Per-run details

After the summary, note: "Per-run details are available in the persisted report at `$REPORT_DIR/telemetry-$TIMESTAMP.json`. Ask for details on a specific ticket to see its full breakdown."

If the user asks for details on a specific run, find it in the JSON and display:
- Step breakdown (name, duration, tools, tokens)
- Agent breakdown (type, step, duration, model, tokens, tools)
- All anomaly flags for that run

## 4. Interpretation

After presenting the data, add at most three sentences of interpretation noting the most significant patterns or anomalies observed. Do not speculate beyond what the data shows.
