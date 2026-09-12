# Claude Code advisory preview adapter

## Selected host evidence

Observed on Claude Code `2.1.258` using only `claude --version`, `claude
--help`, and subcommand help on 2026-09-12. The host accepts a session-local
plugin with `--plugin-dir <path>`. It exposes background-session inspection as
`claude agents --json`, background creation as `claude --bg`, recent output as
`claude logs <id>`, and cancellation as `claude stop <id>`. The documented stop
argument is a background-session `<id>`; it keeps the session resumable.

The help does not document an in-session Agent dispatch API, a native wait API,
Agent argument/result fields, a per-worker cancellation receipt, fresh-context
selection, effective worker model observation, or the field shape/ordering of
worker `PreToolUse` hook payloads. No paid/live probe was authorized. Therefore
the preview is **unsupported** on this evidence: it must not dispatch a review.

## Mapping after qualification

When a future disposable-context probe supplies all missing evidence, map each
T4 `{kind: "spawn", request}` to a named `n1-preview-*` Agent dispatch and
immediately send `{kind: "spawned", requestId, workerId}`. Capture the native
completion text verbatim as `rawText`, construct a T2 result envelope with the
native `workerId`, separately record requested versus observed model values,
and submit `{kind: "result", result, rawText}`. Map a deadline to `timeout`, a
user interruption to `cancel`, and lost native state to `lost-session`. Execute
every returned `{kind: "cancel", workerId}` through the documented qualified
native stop operation and retain its terminal receipt; `{kind: "report"}` maps
only to the controller's local `report` command.

The exact Agent dispatch/wait/result fields remain unverified rather than
invented. This document intentionally does not add an undocumented call to the
shared Python controller.

## Enforcement boundary

The three personas use native `tools: Read, Grep, Glob`, establishing policy
before their first tool call. `enforce-preview.py` is a second layer: a
registered worker permits only those exact names and an absolute path below its
supplied source/input roots; it denies traversal, shell aliases, MCP, nested
agents, and unknown names. It passes unrelated production events. If it is
invoked as worker-scoped with empty or malformed data it denies.

The selected host help does not establish that `SubagentStart` registration
precedes the first worker tool event or that a `PreToolUse` payload identifies a
worker. Until a probe proves both, this hook cannot qualify
`readSearchEnforced`; the native persona allowlist is necessary but insufficient
evidence for the required path-root restriction. Reviewer prompts separately
restrict source/input paths, but that is not a native path-control guarantee.
