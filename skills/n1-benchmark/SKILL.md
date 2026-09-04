---
name: n1-benchmark
description: "Benchmark N1 as an orchestrator across plugin versions: counts human interventions (answers and corrections) per pipeline run from telemetry plus Claude Code transcripts, adds telemetry quality metrics, persists snapshots under ~/.n1/benchmark/, and reports deltas against the previous snapshot and a pinned baseline. Use when asked how N1 is trending, whether a version regressed, or to run the benchmark."
argument-hint: "[--baseline <version>] [--by week] [--since YYYY-MM-DD] [--force]"
model: sonnet
effort: medium
---

# N1 Orchestrator Benchmark

**Announce at start:** "I'm using the n1-benchmark skill to measure orchestrator autonomy across versions."

All deterministic work is done by `scripts/benchmark.py`. This skill only drives it and labels ambiguous human turns with a small judge model. Never compute metrics by hand and never edit files under `~/.n1/<project>/`.

## 1. Resolve paths

```bash
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/benchmark.py"
OUT="${HOME}/.n1/benchmark"
WORK=$(mktemp -d)
PLUGIN_VERSION=$(python3 -c "import json;print(json.load(open('${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json'))['version'])")
```

If `~/.n1` does not exist, tell the user N1 is not configured and stop.

## 2. Pin baseline if requested

If the arguments contain `--baseline <version>`:

```bash
python3 "$SCRIPT" baseline set <version> --out "$OUT"
```

## 3. Collect

```bash
python3 "$SCRIPT" collect --out "$OUT" --ambiguous-out "$WORK/ambiguous.json" [--since DATE] [--force]
```

Read `$WORK/ambiguous.json`. It contains `ambiguous`, a list of `{id, text, prev_assistant}`.

## 4. Judge ambiguous turns

If the list is empty, write `[]` to `$WORK/labels.json` and skip to step 5.

Otherwise split the list into batches of 30. For each batch dispatch ONE Agent call with `subagent_type: general-purpose`, `model: haiku`, and this prompt, substituting the batch as JSON:

```
You label single human messages from a coding-assistant session. For each item you get the human's message (`text`) and the assistant message that preceded it (`prev_assistant`).

Labels (rubric version 1):
- correction: the human says the assistant did something wrong, undoes or redirects an action, or says the result is not what was asked.
- answer: the message replies to a question the assistant asked in prev_assistant.
- approval: the message only permits the assistant to continue (yes, go ahead, looks good).
- instruction: the message starts new work or adds scope, not caused by an assistant error.
- noise: anything else (greetings, slash commands, empty, unrelated).

Return ONLY a JSON array, no prose, one object per input item, same order:
[{"id": "<id>", "label": "<label>", "reason": "<one short sentence>"}]

Items:
<batch JSON>
```

Parse each agent's reply as JSON. If a reply is not valid JSON, retry that batch once; if it still fails, drop it (the script will apply the `instruction` fallback and count it). Concatenate all parsed arrays into `$WORK/labels.json`.

## 5. Finalize and report

```bash
python3 "$SCRIPT" finalize --labels "$WORK/labels.json" --out "$OUT" --plugin-version "$PLUGIN_VERSION" [--by week]
python3 "$SCRIPT" report --out "$OUT" [--by week]
rm -rf "$WORK"
```

Print the report exactly as the script emitted it. Do not summarize it away; the user wants the tables. After it, add at most three sentences of interpretation, and mention if the unlinked list or the insufficient list is long.

## Storage

`~/.n1/benchmark/runs/<run_id>.json` (per-run cache, never re-judged), `snapshots/<id>.json`, `reports/<id>.md`, `baseline.json`. To re-judge everything after a rubric change, run with `--force`.
