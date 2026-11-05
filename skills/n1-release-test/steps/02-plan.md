# Step 2: Case Plan

Write `$N1_HOME/releases/<LABEL>/release-test-plan.md`.

## Sources

For each in-scope ticket, read from `$N1_HOME/memory/<ID>/` when present:
- `ticket.md`: acceptance criteria.
- `local-test-plan.md`: the `### Manual Verification Checklist` items become `manual` or `assisted` cases; the `### Automated Test Scenarios` inform `auto` cases.
- `post-deploy-verification.md`: a criterion already recorded as `SKIPPED` or `FAIL` becomes a case; a recorded `PASS` lowers its risk by no more than one tier.

When a ticket has no `ticket.md`, read its acceptance criteria with `mcp__<tracker.mcp>__<operations.readTicket>`. If that fails, add one `manual` case for the ticket with the reason "no acceptance criteria available".

Read the `--stat` summary at the top of `release.diff`, then add cross-ticket regression cases for risky areas of the diff: files or services changed by two or more tickets, and shared code whose callers no ticket covers.

## Rules

**Case ID:** `RT-NN`. If the plan file already exists for this label, keep its rows and IDs and add new cases with the next free number; never renumber, because QA results are carried by ID. Remove a row only when its ticket left the scope.

**Risk tier**, from the diff paths the case covers:
- `Critical`: authentication, authorization, secrets, or data loss paths.
- `High`: data models, migrations, public API or contract changes.
- `Medium`: other behaviour changes.
- `Low`: documentation, copy, tooling and tests only.

**Class**, following the automated versus manual split in `agents/local-test-planner.md`:
- `auto`: read-only steps that `dev-access.md` or configured observability supports, with an outcome a command can decide.
- `assisted`: read-only steps the verifier can run, with an outcome a human must confirm.
- `manual`: needs human judgement (visual UI, complex multi-step workflows) or changes state on dev.

When `$N1_HOME/dev-access.md` does not exist, every case is `manual` with the reason `no dev-access.md`.

## Format

One table, one row per case. Every cell stays on one line, `|` is written as `\|`, and steps are joined as `1) <step> -> <expected>; 2) <step> -> <expected>`.

```markdown
# Release test plan <LABEL> (<PREV>..HEAD)

Tickets: <ID>, <ID>

| ID | Tickets | Risk | Class | Reason | Preconditions / test data | Steps and expected |
|---|---|---|---|---|---|---|
| RT-01 | <ID> | High | auto | <why this class> | <preconditions and test data, or none> | 1) <step> -> <expected> |
```
