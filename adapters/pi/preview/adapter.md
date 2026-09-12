# Pi advisory preview adapter

## Selected host evidence

This package is isolated under `adapters/pi/preview`: it pins
`@earendil-works/pi-coding-agent` `0.85.1` and declares Node
`>=24.19.0 <25`. Qualification used Node `24.19.0` and Pi `0.85.1`.
Neither dependency is added to the repository root, so production Claude flows
do not need Node or Pi.

Installed-host `--help` output confirms that `--no-extensions` disables
discovery while explicit `--extension` paths still load, `--no-session` makes
the session ephemeral, the skill/template/theme discovery disable flags exist,
`--offline` disables startup network work, and `--tools` is an allowlist across
built-in and extension tools. An offline help probe loaded `review.ts` through
an explicit absolute extension path. Built-in Node tests execute the Pi 0.85.1
`tool_call` payload shapes for `read`, `grep`, `find`, and `ls`, including their
different optional `path` fields, and exercise the canonical-path guard.

No live or paid model call was authorized. Consequently native first-tool hook
ordering and fresh-context instruction loading were not observed end to end.
The package reports `readSearchEnforced` and `isolatedContext` as `unverified`;
the shared preflight rejects them before source preparation or worker dispatch.
This is intentionally fail closed until a disposable qualification run supplies
native receipts.

## Qualified controller and worker mapping

After qualification, `/n1-review-preview owner/repo#123` captures the current
Pi provider, model ID, and thinking level. It rejects a missing value or a model
absent from the native registry rather than applying Pi defaults. It invokes
the packaged Bash controller with argument arrays, starts both T4 reviewer
actions before awaiting either, registers every native PID before accepting a
result, aborts siblings on the first failure, and awaits all reviewer settlement
before executing the reducer-returned verifier action. Session shutdown aborts
and joins all owned work; no resume is inferred.

Each worker is a fresh package-local Pi executable with `shell:false`, an
explicit source cwd, no session, no discovered extensions or resources,
offline startup, and exactly `read,grep,find,ls`. The trusted explicit guard
bounds canonical paths to the pinned source plus controller-declared role input
files and returns `{block:true, reason:"N1 reviewer tool unavailable"}` for
unknown, mutating, malformed, missing, or escaping calls. Prompt files and CLI
event/evidence files are controller-owned scratch artifacts; reviewers cannot
write.

The bridge incrementally parses JSONL, ignores tool-event text as role output,
requires a final successful assistant message and zero exit, preserves split
UTF-8, and caps combined stdout/stderr at 10 MiB. Abort or timeout targets the
POSIX process group with `SIGTERM`, escalates to `SIGKILL` after two seconds,
and does not treat an unobserved close as confirmed cancellation.
