---
name: n1-review-runtime
description: Use when an explicit owner/repo#123 target needs opt-in advisory runtime-preview qualification in Codex.
---

# N1 Advisory Review Preview

Invoke only as `$n1-review-runtime owner/repo#123`, with the host fixed to `codex`.
This preview is advisory and read-only. It may display only a
controller-rendered local report; it never approves an incomplete review.

## Current capability gate

Run the packaged preflight guard before the shared bridge:

```bash
python3 "${CODEX_PLUGIN_ROOT}/preflight.py" "owner/repo#123"
```

It consumes only its package-owned qualification record and accepts no
caller-supplied capability evidence. This package version is **unsupported**,
so the guard stops before calling the shared controller, preparing source, or
dispatching an agent. Static configuration,
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
schema. Qualification must identify and record a supported role/profile binding
that selects each exact packaged profile; a generic spawn with a descriptive
label does not select one and is never a fallback. Until a real binding and its
arguments/results are proven, remain unsupported and do not dispatch.

After qualification, use only the proven bindings for
`n1_runtime_code_reviewer` and `n1_runtime_security_reviewer`, with the supplied
request, packaged role instructions, and controller-resolved model/effort
policy. Register both returned native handles and submit both T4 `spawned`
events before waiting.

Wait through `collaboration.wait_agent` up to each request's 600-second
deadline. Convert only actual native output and metadata into observed envelopes,
retain its exact text as `rawText`, and submit it with T4 `event`.
Never invent a `completed` record. On timeout, interruption, lost state, or any
failed result, submit the corresponding T4 event, invoke
`collaboration.interrupt_agent` for every returned cancel action, and retain
native terminal cancellation receipts before reporting.

Start `n1_runtime_review_verifier` through its proven profile binding only when
T4 returns that spawn action. Give it claims and permitted source/conventions
inputs in a fresh nonforked context, never sibling raw results, parent
conversation, credentials, or controller state. Apply the same deadline,
observation, and cancellation rules. Invoke the T4 `report` command only after
all actions and receipts have been reconciled, then display only its
controller-rendered local report.

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
