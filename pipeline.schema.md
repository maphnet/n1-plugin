# pipeline.json Schema

`pipeline.json` is the canonical, declarative source of truth for N1's
pipeline structure. It is consumed by n1-start (the model reads it via the Read
tool) for type resolution, dependency declarations, config gates, and loop
bounds. `docs/` is gitignored, so this schema lives beside the data file.

## Top-level

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Schema version. |
| `downgrade_triggers` | object | Signal conditions that downgrade an agent's model tier (`<agent>:<step>` → `{condition, tier}`). |
| `escalation_triggers` | object | Signal conditions that escalate an agent's model tier (`<agent>:<step>` → `{condition, tier}`). |
| `types` | object | Pipeline type registry: per-type step sequence, detection rules, and optional `step_overrides`. |
| `steps` | array | The canonical pipeline steps. |
| `manual_only` | string[] | Steps that are never entered automatically (release). |
| `gates` | array | The config gates that skip a step. |
| `loops` | array | The bounded fix loops. |

## `steps[]`

Each entry: `{name, number, agent, reads, writes}`.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Canonical step name. |
| `number` | int | 1-based ordinal. |
| `agent` | string | Primary persona or sub-skill invoked. Informational; the review context asymmetry (code-reviewer vs security-reviewer bundles) stays prose in `review-core.md`. |
| `reads` | string[] | Hard dependency files, verified by `n1_verify_dependencies` before the step runs. |
| `writes` | string[] | Primary output file(s). `local-testing` sub-steps collapse to `local-testing.md`. |

## `gates[]`

Each entry: `{name, config_key, default, skips}`.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Gate identifier. |
| `config_key` | string | Dotted key in `$N1_HOME/config.json`. |
| `default` | bool | Value when the key is absent. |
| `skips` | string[] | Step name(s) skipped when the gate is closed. |

## `loops[]`

Each entry: `{name, trigger_step, trigger_outcome, fix_step, retry_step, counter, max_config_key, max_default}`.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Loop identifier. |
| `trigger_step` | string | Step whose failing outcome opens the loop. |
| `trigger_outcome` | string | Outcome that triggers the loop (`fail`). |
| `fix_step` | string \| null | Step that performs the fix. `null` for `ci_fix` (n1-ci owns its loop internally). |
| `retry_step` | string | Step re-run after a fix. |
| `counter` | string | Frontmatter counter tracked in `overview.md`. |
| `max_config_key` | string | Dotted config key for the bound. |
| `max_default` | int | Bound when the key is absent (all four default to 3). |

`review.maxFixAttempts` is a config key introduced by N1-6 so all four loops are
uniform; before N1-6 the review loop bound was hardcoded `3`.

## Consumers

1. **n1-start (model):** reads this file for type resolution (`types`), dependency
   declarations (`steps[].reads`), model-tier triggers, and `gates`/`loops` for
   skip and bound decisions.
2. **validation.sh (bash):** `n1_resolve_type` reads `types` for the detection
   cascade; `n1_verify_dependencies` checks the declared dependency files.
