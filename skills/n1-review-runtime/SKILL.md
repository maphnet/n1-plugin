---
name: n1-review-runtime
description: Use when an explicit owner/repo#123 target needs opt-in advisory runtime-preview qualification in Claude Code.
argument-hint: owner/repo#123
---

# N1 Advisory Review Preview

This is an opt-in, read-only qualification preview. It may report only the
controller-rendered local report; it never approves an incomplete review.

## Target and capability gate

Accept exactly an explicit `owner/repo#123` target. Reject a missing, local,
branch-only, or non-explicit target before any controller action.

Run the packaged preflight guard before the shared bridge. It consumes its own
current capability record; it accepts no caller-supplied capability evidence:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/adapters/claude-code/preview/preflight.py" "owner/repo#123"
```

The shipped record is unverified, so this command returns `unsupported` and the
skill stops. It does not invoke `lib/runtime-review.sh`, `prepare`, Agent,
wait, or stop. The existing bridge (which calls `n1_home()`) remains the only
trusted launcher for a future qualified controller; do not replace it with a
checkout-local Python command.

## Qualified dispatch only

No native dispatch is enabled by this package version. If future disposable
qualification changes that state, each returned spawn action must configure the named native agent
(`n1-runtime-code-reviewer` or `n1-runtime-security-reviewer`) with the
frontmatter read/search allowlist before its first tool call. Resolve model
policy through native configuration and retain requested and observed settings
separately. Start both named reviewer agents before waiting; give each only its
individual request/input paths and the pinned working directory, never parent
conversation history. Record both native handles immediately and submit a
`spawned` event for each.

The future qualified flow must wait for native completions up to each request's 600-second default deadline.
Capture raw worker text as `rawText`, validate the resulting envelope, and
submit it through `event`. On a failure, timeout, interruption, or lost session,
send the matching controller event, cancel every remaining native handle, and
await terminal receipts. A Markdown instruction to stop is not a receipt.

Only if `event` returns a verifier spawn action may the future qualified flow start
`n1-runtime-review-verifier` in a fresh context. Pass only claims plus permitted
source/conventions paths; it must not receive sibling results or controller
`state.json`. Apply the same model, deadline, rawText, and cancellation rules.
Finally invoke `report` and display only its controller-rendered local report.

## Unsupported host behavior

Do not substitute shell processes, undocumented tool calls, inferred model
selection, or prose promises for missing native support. If dispatch, wait,
stop, fresh context, path restriction, or effective-model observation cannot be
demonstrated by the selected host version, preflight returns unsupported and no
approval is reported.
