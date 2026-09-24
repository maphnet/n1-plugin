# Host Routing

N1 skill text is host-neutral. It names *what* to do; this table says *how* on each host.
The session-start hook injects the row for the running host as a `HOST ROUTING` block, and
`N1 PLUGIN ROOT: <path>` for the `<N1_ROOT>` placeholder. Update this file when a host
changes syntax; skills never name host tools directly (enforced by
`tests/test_host_neutral_skills.sh`).

| Skill text says | Claude Code | Codex |
|---|---|---|
| dispatch persona `<name>` with `<prompt>` | resolve with `n1_resolve_agent <name> <step-context> [astra-context]`, then use its tab-separated `model<TAB>effort` result with `Agent`, `subagent_type: "n1:<name>"`, `prompt`, `model: <m>` | resolve with `n1_resolve_agent <name> <step-context> [astra-context]`; its tab-separated model/effort result is authoritative. Inspect the available `spawn_agent` schema at dispatch time. Only pass `agent_type` when that field is supported; then use `"n1-<name>"` to select the generated persona profile. Otherwise, read `agents/<name>.md` and embed its complete instructions plus the resolved model/effort in the fork-none message. Pass model/effort fields when supported, otherwise retain them in that message. In either route preserve the complete prompt (persona brief, workspace, constraints, and result contract). |
| dispatch a general-purpose subagent | `Agent` tool, `subagent_type: "general-purpose"` | `spawn_agent` without `agent_type`, `fork_turns: "none"` |
| fork prohibition | Never use subagent_type "fork". All dispatches use typed personas or general-purpose subagents with fresh context. | Already covered by `fork_turns: "none"` on every dispatch. |
| wait for it | a dispatch may return inline or queued/running; wait for its mailbox/result completion before proceeding | `wait_agent` with a bounded `timeout_ms` (5-10 minutes). On timeout, wait again for the same worker; never dispatch a replacement because a wait timed out. A dispatch may return queued or running; wait for its mailbox/result completion before proceeding. |
| dispatch a headless child | `n1_headless_cmd <skill> <args> <model> <outfile> [repo] [effort] [brief-file]` via Bash | `n1_headless_cmd <skill> <args> <model> <outfile> [repo] [effort] [brief-file]` via Bash. This is transport only: retain the selected persona, model/effort, workspace, constraints, brief, and result contract. |
| fix loop: next cycle for the same agent | dispatch a fresh persona | If the active host exposes `followup_task` or `send_message`, use the available same-worker continuation with the new findings; otherwise dispatch a fresh persona. Do not use `send_input` unless it is actually exposed. |
| ask the user | Use an available question tool within its advertised constraints; otherwise end the turn with numbered plain-text options. | Use an available question tool within its advertised constraints; otherwise end the turn with numbered plain-text options. |
| load the tool if deferred | Use a tool-discovery facility only when it is available; otherwise use the tools already exposed to the session. | Use a tool-discovery facility only when it is available; otherwise use the tools already exposed to the session. |
| invoke skill `<x>` | `/n1:n1-<skill>` | `$n1-<skill>` |
| `<N1_ROOT>` | value of `N1 PLUGIN ROOT` (`${CLAUDE_PLUGIN_ROOT}` env var, set by the harness) | value of `N1 PLUGIN ROOT` (`${PLUGIN_ROOT}` env var set by Codex; `~/.n1/host.json` as last-resort fallback) |
| worktree root | `worktree.root` from config, else `.claude/worktrees` | `worktree.root` from config, else `.codex/worktrees` |
| headless child run | `claude -p "/n1:<skill> <args>" --model <m> --permission-mode bypassPermissions --output-format stream-json --verbose` | `codex exec --cd <repo> -c model="<m>" --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust '$<skill> <args>'` |
| background child run (n1-queue) | built by `n1_bg_launch_cmd` / `n1_bg_cmd` (`lib/host.sh`): cwd = repo, `claude --bg --name n1-<queue>-<ticket>-<row> --model <m> --permission-mode bypassPermissions --settings '{"env":{N1_HEADLESS,N1_AUTONOMY_PRESET,N1_STOP_AT,N1_QUEUE_RUN_ID,N1_HOST,N1_PARENT_SESSION_ID,N1_UNATTENDED},"worktree":{"bgIsolation":"none"}}' "/n1:<skill> <args>"` (the session supervisor does not inherit the caller's env); stdout `backgrounded · <id> · <name>`. Poll `claude agents --json --all` (`state`: working/blocked/done/failed/stopped), stop `claude stop <id>`, resume `claude attach <id>`. Once per machine, accept the bypass-permissions disclaimer by running `claude --dangerously-skip-permissions` interactively. | not used; queue children use the headless child run |
| persona definitions | `agents/<name>.md` shipped in the plugin | `.codex/agents/n1-<name>.toml` generated at session start from the same files; never edit them |
| persona tool restriction | native `tools:` frontmatter, duplicated by `hooks/enforce-agent-policy.py` | `hooks/enforce-agent-policy.py` (denies `apply_patch` and agent tools outside the list) plus `sandbox_mode = "read-only"` for read-only personas |
| hook trust | none | once per plugin version via `/hooks`; headless children pass `--dangerously-bypass-hook-trust` |
| queue watch hint | watch via `claude agents` (live per-ticket state) or `/n1:n1-queue --status` | watch via `/n1:n1-queue --status` |
| background event watch (n1-queue) | `Monitor` running the exact `n1_queue_watch` command the skill gives, with the maximum timeout (30 min). Each stdout line arrives in this session as a notification; relay it to the user verbatim. On the timeout notice, re-run the identical command unless the watch already printed a line ending in `Watch ended.` (its cursor resumes with no gap and no replay). | not supported: start no watch. Alerts come only from `queue.notify`; check with `$n1-queue --status <id>`. |

> **BLOCKING DISPATCH REQUIREMENT (pipeline steps):** All persona dispatches within pipeline step files MUST remain foreground from the orchestrator's perspective. Do NOT continue to the next pipeline instruction until the dispatched worker has completed and its result is available, whether completion is returned inline or delivered through a native mailbox/wait mechanism. Fabricating a completion event or checking for output before completion is a critical protocol violation that discards specialist work.

## Bash snippet preamble

Capabilities are checked against the active tool schema, not just the host name.
Codex CLI 0.154.0 supports `exec -c model_reasoning_effort=...`; other harnesses
may expose native model/effort arguments. Including model/effort in a message is
context only and cannot enforce runtime configuration. If neither native
arguments nor an equivalent configured profile/transport can preserve the pair,
report the unsupported capability before dispatching. `send_message` can reach a
running worker but may not restart an idle one; use `followup_task` for that when
exposed. A wait timeout is not worker completion or permission to restart it.

Every skill bash snippet that needs plugin files starts with this line. Each fenced block runs in a fresh shell, so every block repeats it:

```bash
source ~/.n1/preamble.sh
```

`~/.n1/preamble.sh` is a one-line trampoline generated by `hooks/session-start.sh` next to `~/.n1/host.json` on every startup, resume, clear and compact, on both hosts; it is written, not symlinked, so it works in Git Bash/MSYS without native symlink support. Its content never varies between sessions or versions: it sources `~/.n1/sessions/<sid>.preamble.sh`, where `<sid>` is `N1_SESSION_ID`, else `CLAUDE_CODE_SESSION_ID` (Claude Code), else `CODEX_THREAD_ID` (Codex), all set in the shell env by the harness. The per-session file, written by that session's own hook, sets `N1_ROOT` to that session's plugin root and sources `lib/preamble.sh`, which sources `lib/config.sh` (which sources `lib/host.sh`), `lib/step.sh` and `lib/validation.sh`, and sets `N1_HOME`. Concurrent sessions with different N1 versions or hosts therefore never share a root (NP-204); a missing id or file fails loudly instead of running another session's version. If a snippet runs an unexpected version, inspect `~/.n1/sessions/<sid>.preamble.sh`. Session files older than 7 days are pruned at session start. Specialized libs are sourced after the preamble as `source "$N1_ROOT/lib/<lib>.sh"`. Never resolve `N1_ROOT` inline; `tests/test_host_neutral_skills.sh` rejects it.

## Model routing

`models.<persona>` in `$N1_HOME/config.json` is a string (legacy, Claude only) or an object
keyed by host: `{"claude-code": "opus", "codex": "gpt-5.6-terra"}`; the `codex` value may be
`{"model": "...", "reasoning_effort": "..."}`. Dispatchers call
`n1_resolve_agent <persona> [step_context] [astra_context]` in `lib/config.sh` and split its
tab-separated `model<TAB>effort` return. `n1_resolve_model` remains a model-only compatibility
helper; it is not the dispatch interface.

For models, precedence is exactly **override > escalation > downgrade > task type > baseline**.
Known frontmatter roles use the shared host translation: Claude retains `opus`, `sonnet`, and
`haiku`; Codex maps them to `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` respectively.
Known roles never use Codex's CLI default; an unknown persona falls back to that default (or the
legacy host fallback when it is absent).

On Codex, effort precedence is **explicit persona/host effort > global Codex default > persona
frontmatter > `medium`**. The final policy floor is `medium`: `low` is accepted only to warn and
clamp to `medium`, and an unsupported value likewise warns and resolves to `medium`.

`gpt-6-astra` is an opt-in explicit override, never an automatic tier result. It is retained only
when the caller has verified one of these exact contexts: `final-whole-branch-review`,
`architecture-adjudication`, or `failed-fix-escalation` (the last requires `review_fix_cycle >=
2`). Missing, malformed, or ineligible context warns and continues through ordinary tier
resolution.

Generated Codex profiles are context-free generated profiles: for the same persona and
configuration, they have exact baseline model/effort parity with context-free runtime resolution.
Runtime may differ only when a declared escalation, downgrade, task-type override, or eligible
explicit Astra override applies.
