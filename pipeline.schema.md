# pipeline.json Schema (v1)

`plugin/pipeline.json` is the canonical, declarative source of truth for N1's
pipeline routing. It is consumed by n1-start (the model reads it via the Read
tool) and by n1-loop (`loop/n1_loop/pipeline.py` parses it). `plugin/lib/validation.sh`
mirrors a subset (step names/numbers/reads) as hardcoded bash and is held in
parity by `loop/tests/test_plugin_validation.py`. `docs/` is gitignored, so this
schema lives beside the data file.

## Top-level

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Schema version. Currently `1`. |
| `steps` | array | The 13 canonical pipeline steps. |
| `gates` | array | The 4 config gates that skip a step. |
| `loops` | array | The 4 bounded fix loops. |
| `routing` | array | The conditional next_step edge model. |

## `steps[]`

Each entry: `{name, number, agent, reads, writes}`.

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Canonical step name (one of the 13). |
| `number` | int | 1-based ordinal (matches `n1_step_number`). |
| `agent` | string | Primary persona or sub-skill invoked. Informational; the review context asymmetry (code-reviewer vs security-reviewer bundles) stays prose in `review-core.md`. |
| `reads` | string[] | Hard dependency files, exactly equal to bash `n1_step_dependencies`. Enforced by the consistency test. |
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

## `routing[]`

Each entry: `{step, outcome, next, when}`. Rows are evaluated top-to-bottom; the
first row matching `(step, outcome)` whose `when` evaluates truthy wins. `next: null`
terminates the pipeline.

### `when` mini-language

| Form | Meaning |
|------|---------|
| `null` | Always true. |
| `"plan"` / `"direct"` | Brainstorm planning need branch. The brainstormer evaluates design sufficiency (step 8b in autonomous-brainstorm.md, Planning Need Evaluation in brainstorm.md) and sets `planning_need` in its step result; the edge names the branch taken. |
| `{"config": "<dotted.key>", "eq": <v>}` | Config value equals `<v>` (using the gate/loop default when absent). |
| `{"config": "<dotted.key>", "neq": <v>}` | Config value not equal to `<v>`. |
| `{"all": [<cond>, ...]}` | All sub-conditions true. |
| `{"any": [<cond>, ...]}` | Any sub-condition true. |
| `{"counter": "<name>", "lt": "<config.key>"}` | Counter value `<` the resolved bound. |
| `{"counter": "<name>", "gte": "<config.key>"}` | Counter value `>=` the resolved bound. |
| `{"overview_step": "qa"\|"review"}` | The `step:` field in `overview.md` equals the value (fix-target inference). |

## Consumers

1. **n1-start (model):** reads this file, evaluates the routing edge for
   `(step, outcome, current config)` to compute `next_step`, and uses `gates`/`loops`
   for skip and bound decisions.
2. **validation.sh (bash):** hardcoded mirror of step names/numbers/reads; parity
   enforced by CI test. Preserves the jq-optional invariant (no bash JSON parsing).
3. **loop (Python):** `pipeline.py` loads this file; `router.derive_next_step` derives
   edges; `session.infer_next_step` uses it for tier-3 recovery.
