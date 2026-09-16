# Host Routing

N1 skill text is host-neutral. It names *what* to do; this table says *how* on each host.
The session-start hook injects the row for the running host as a `HOST ROUTING` block, and
`N1 PLUGIN ROOT: <path>` for the `<N1_ROOT>` placeholder. Update this file when a host
changes syntax; skills never name host tools directly (enforced by
`tests/test_host_neutral_skills.sh`).

| Skill text says | Claude Code | Codex |
|---|---|---|
| dispatch persona `<name>` with `<prompt>` | resolve with `n1_resolve_agent <name> <step-context> [astra-context]`, then use its tab-separated `model<TAB>effort` result with `Agent`, `subagent_type: "n1:<name>"`, `prompt`, `model: <m>` | resolve with `n1_resolve_agent <name> <step-context> [astra-context]`, then use its tab-separated `model<TAB>effort` result with `spawn_agent`, `agent_type: "n1-<name>"`, `fork_turns: "none"`, `task_name`, `message: <prompt>`, `model: <m>`, `reasoning_effort: <effort>` |
| dispatch a general-purpose subagent | `Agent` tool, `subagent_type: "general-purpose"` | `spawn_agent` without `agent_type`, `fork_turns: "none"` |
| wait for it | the tool call returns the result inline | `wait_agent` (bounded `timeout_ms`, 5-10 minutes); the final answer arrives in the mailbox |
| dispatch long-running implementation persona | `Agent` tool (blocking, same as any persona) | headless child: `n1_headless_cmd n1-implement "<ID> plan=<plan-file> output=<output-file>" <model> <outfile> [repo]` via Bash — blocks until child exits, no timeout ceiling; see `skills/n1-start/steps/implementation.md` |
| fix loop: next cycle for the same agent | dispatch a fresh persona | keep the agent open; `send_input` with the new findings; `close_agent` only if the session offers it |
| ask the user | `AskUserQuestion` tool (max 4 questions per call) | end the turn with a plain message listing numbered options; there is no question tool |
| load the tool if deferred | `ToolSearch` with `select:<tool>` | skip: all tools are preloaded |
| invoke skill `<x>` | `/n1:n1-<skill>` | `$n1-<skill>` |
| `<N1_ROOT>` | value of `N1 PLUGIN ROOT` (Claude also expands `${CLAUDE_PLUGIN_ROOT}` inside bash snippets) | value of `N1 PLUGIN ROOT` (read at runtime from `~/.n1/host.json`) |
| worktree root | `worktree.root` from config, else `.claude/worktrees` | `worktree.root` from config, else `.codex/worktrees` |
| headless child run | `claude -p "/n1:<skill> <args>" --model <m> --permission-mode bypassPermissions --output-format stream-json --verbose` | `codex exec --cd <repo> -c model="<m>" --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust '$<skill> <args>'` |
| persona definitions | `agents/<name>.md` shipped in the plugin | `.codex/agents/n1-<name>.toml` generated at session start from the same files; never edit them |
| persona tool restriction | native `tools:` frontmatter, duplicated by `hooks/enforce-agent-policy.py` | `hooks/enforce-agent-policy.py` (denies `apply_patch` and agent tools outside the list) plus `sandbox_mode = "read-only"` for read-only personas |
| hook trust | none | once per plugin version via `/hooks`; headless children pass `--dangerously-bypass-hook-trust` |

> **BLOCKING DISPATCH REQUIREMENT (pipeline steps):** All persona dispatches within pipeline step files MUST be blocking (foreground). Do NOT dispatch pipeline step agents asynchronously or in the background. The agent tool call must return its result inline before the orchestrator reads any output files or proceeds to the next instruction. Fabricating a completion event or checking for output before the tool call returns is a critical protocol violation that discards specialist work.

## Bash snippet preamble

Every skill bash snippet that needs plugin files starts with this line; `lib/config.sh` sources `lib/host.sh`:

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
```

On Claude Code the token is substituted before the model sees it. On Codex the literal
survives, the variable is empty in the shell, and `host.json` supplies the root.

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
