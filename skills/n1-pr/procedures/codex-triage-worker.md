# Procedure: Codex Triage Worker

Read by the `tail-worker` persona in `mode: codex-triage`, dispatched twice from `skills/n1-pr/procedures/codex-triage.md` before the push (no PR exists yet), or once with `phase: validate` from `skills/n1-start/procedures/review-codex.md` (n1-start Step 7). Phase `fix` runs State, Severity Parsing, Validation and Fix Cycle and ends after the developer commits (never pushes). Phase `report` runs Triage Reply after the orchestrator's scope gate. State crosses the two dispatches only through files in `<S>`, the `codex-validate-<KEY>.*` directory created below.

Write every file named here (`state.md`, `candidates.md`, `confirmed.md`, `developer.md`, the triage file) with the file-write mechanism (`references/file-write-mechanism.md`), never through a shell command (redirect, heredoc, `cp`, `cat`, `printf`, `tee`, `sed -i`). Never place finding, validator or developer text in a shell command, variable or double-quoted string, and never in your return: return only the status lines named below.

In phase `fix`, "skip to Triage Reply" below means: record the routing in `<S>/state.md` and return `triage:fix state=<S> developer=none`.

Triage has no user prompts and never blocks the pipeline: every failure below routes the affected findings to human review and continues. Unattended and headless runs follow exactly the same path.

## Phase Files

Read this file, then only the files your `phase` input names, in order, all in `<n1_root>/skills/n1-pr/procedures/`:

| `phase` | Read |
|---|---|
| `fix` | `codex-triage-worker-core.md`, then `codex-triage-worker-fix.md` |
| `validate` | `codex-triage-worker-core.md`, then `codex-triage-worker-validate.md` |
| `report` | `codex-triage-worker-report.md` |
