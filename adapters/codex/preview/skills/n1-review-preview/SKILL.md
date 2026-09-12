---
name: n1-review-preview
description: Use when an explicit owner/repo#123 target needs opt-in advisory runtime-preview qualification in Codex.
---

# N1 Advisory Review Preview

Invoke only as `$n1-review-preview owner/repo#123`, with the host fixed to `codex`.
This preview is advisory and read-only. It may display only a
controller-rendered local report; it never approves an incomplete review.

## Current capability gate

This package version is **unsupported** and must stop before calling the shared
controller, preparing source, or dispatching an agent. Static configuration,
the role `sandbox_mode`, and documentation do not prove native enforcement.
The package hook is intentionally unregistered because plugin-hook trust,
preview-worker identity, per-run policy binding, and pre-first-tool ordering
have not been exercised in an authorized disposable Codex environment.

Do not install the packaged role templates into an existing `.codex/agents`
directory. A future qualification installer may materialize them only in its
dedicated environment after an explicit install choice. Never use hook-trust or
sandbox bypass flags.

## Qualified native mapping

The following mapping is inert until the capability gate has native evidence
for dispatch, isolation, read/search denial receipts, deadlines, cancellation,
and observed model/provider/effort values.

Use the existing T4 CLI and each returned prepared request without changing its
schema. For the initial batch, call `collaboration.spawn_agent` twice with the
distinct custom-agent task names `n1_preview_code_reviewer` and
`n1_preview_security_reviewer`; use `fork_turns: "none"`, the supplied request
and packaged role instructions as the message, and the controller-resolved
model/effort arguments. Register both returned native handles and submit both
T4 `spawned` events before waiting. There is no generic-role fallback.

Wait through `collaboration.wait_agent` up to each request's 600-second
deadline. Convert only actual native output and metadata into observed envelopes,
retain its exact text as `rawText`, and submit it with T4 `event`.
Never invent a `completed` record. On timeout, interruption, lost state, or any
failed result, submit the corresponding T4 event, invoke
`collaboration.interrupt_agent` for every returned cancel action, and retain
native terminal cancellation receipts before reporting.

Spawn `n1_preview_review_verifier` only when T4 returns that spawn action. Give
it claims and permitted source/conventions inputs in a fresh nonforked context,
never sibling raw results, parent conversation, credentials, or controller
state. Apply the same deadline, observation, and cancellation rules. Invoke the
T4 `report` command only after all actions and receipts have been reconciled,
then display only its controller-rendered local report.

## Enforcement boundary

A future qualified controller must generate a read-only worker policy outside
model-controlled arguments, set its path and digest in the worker environment,
and bind absolute Python/reader paths in a non-login shell with startup files
disabled. The only permitted worker shell call is the canonical four-argument
`reader.py read|search VALUE` bridge. Source reads use snapshot-relative paths;
each T4 input is exposed only as `inputs/<input-name>` after its absolute path
is placed in that role's policy. All other shell, patch, network/MCP,
connector, dynamic-discovery, and nested-delegation tools deny. If native
configuration cannot establish those properties before the first tool call,
or if hooks are missing, untrusted, disabled, or cannot identify worker scope,
the preview remains unsupported.
