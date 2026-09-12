---
name: n1-review-preview
description: Use when an explicit owner/repo#123 target needs opt-in advisory runtime-preview qualification in Claude Code.
argument-hint: owner/repo#123
---

# N1 Advisory Review Preview

This is an opt-in, read-only qualification preview. It may report only the
controller-rendered local report; it never approves an incomplete review.

## Target and capability gate

Accept exactly an explicit `owner/repo#123` target. Reject a missing, local,
branch-only, or non-explicit target before any controller action.

Resolve the controller home through the existing bridge, which calls `n1_home()`.
The controller supplies its trusted paths; do not replace its bridge with a
checkout-local Python command:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/../../../lib/runtime-review.sh" preflight \
  --host claude-code --capabilities <controller-owned-capabilities.json> \
  --observed <controller-owned-observations.json>
```

Before preparation, require current native evidence for `readSearchEnforced`,
`isolatedContext`, and `lifecycleControl`, plus requested and observed model
settings for every role. Run the packaged `preflight`, then `prepare`, only
with controller-owned capability/observation files and configuration. If any
capability is unavailable or unverified, return `unsupported` with its exact
reason; do not dispatch a worker. In particular, this adapter's installed-host
evidence does not establish worker-scoped hooks, fresh contexts, path
restriction, effective model selection, or in-session Agent wait/cancel calls.

## Qualified dispatch only

For each returned spawn action, configure the named native agent
(`n1-preview-code-reviewer` or `n1-preview-security-reviewer`) with the
frontmatter read/search allowlist before its first tool call. Resolve model
policy through native configuration and retain requested and observed settings
separately. Start both named reviewer agents before waiting; give each only its
individual request/input paths and the pinned working directory, never parent
conversation history. Record both native handles immediately and submit a
`spawned` event for each.

Wait for native completions up to each request's 600-second default deadline.
Capture raw worker text as `rawText`, validate the resulting envelope, and
submit it through `event`. On a failure, timeout, interruption, or lost session,
send the matching controller event, cancel every remaining native handle, and
await terminal receipts. A Markdown instruction to stop is not a receipt.

Only if `event` returns a verifier spawn action, start
`n1-preview-review-verifier` in a fresh context. Pass only claims plus permitted
source/conventions paths; it must not receive sibling results or controller
`state.json`. Apply the same model, deadline, rawText, and cancellation rules.
Finally invoke `report` and display only its controller-rendered local report.

## Unsupported host behavior

Do not substitute shell processes, undocumented tool calls, inferred model
selection, or prose promises for missing native support. If dispatch, wait,
stop, fresh context, path restriction, or effective-model observation cannot be
demonstrated by the selected host version, preflight returns unsupported and no
approval is reported.
