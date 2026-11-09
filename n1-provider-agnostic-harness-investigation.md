# N1 Provider-Agnostic Coding-Agent Harness Investigation

This is the durable handoff and running investigation record. It covers the complete decision: choose a coding-agent harness, determine whether N1 can migrate to it, and make the harness switch among supported model/provider options without rewriting N1 workflows.

Update this file whenever new evidence changes a conclusion, freshness assessment, migration risk, or recommendation. Keep claims evidence-backed and dated.

## 1. Decision question

Which open-source coding-agent system should host a provider-agnostic N1 pipeline, and what adapter/configuration work is required to preserve N1 behavior while allowing the operator to select among:

- Codex/ChatGPT subscription or supported OpenAI sign-in
- Anthropic/Claude subscription or Anthropic API
- z.ai/GLM subscription or API, where officially supported
- local vLLM and other OpenAI-compatible servers
- OpenRouter or another multi-provider gateway
- models such as Qwen, DeepSeek, GLM, and comparable coding models

The desired result is a selectable provider list and a stable N1 workflow, not a single hard-coded model or a gateway-only solution.

## 2. N1 baseline to preserve

The reference implementation is the existing N1 pipeline and `~/dev/n1-codex` fork. The investigation must map each item below to native harness behavior, an extension, or a small N1 adapter:

| N1 capability | Required migration result |
|---|---|
| Personas and model overrides | Each persona can select or inherit a provider/model; overrides remain inspectable. |
| Skills and project instructions | AGENTS/CLAUDE-style instructions, skills, and references reach every relevant agent. |
| Analysis → brainstorm → plan → implement → QA → review gates | Pipeline sequencing and stop conditions survive provider changes. |
| Signals and confidence routing | Findings and confidence can be persisted and used for routing. |
| Memory and investigation artifacts | Durable files remain the source of truth across sessions and models. |
| Queues and unattended workers | Jobs can start, resume, cancel, retry, and clean up without orphan processes. |
| Tracker operations | Ticket updates remain explicit, auditable, and provider-independent. |
| Telemetry | Provider, model, latency, tokens/cost, errors, retries, and fallbacks are recorded. |
| Permissions and review gates | Read-only reviewers cannot edit; dangerous actions remain gated. |
| Worktrees and isolation | Agents operate in the intended worktree with predictable cleanup. |
| Resume/recovery | Interruptions do not duplicate work or lose the durable state. |
| Subagents and parallel review | Harness supports isolated subagents or N1 can provide the orchestration layer. |

## 3. Candidate harnesses

### OpenCode v2

Current leading candidate because it combines a mature coding-agent UX with configurable providers, agents, permissions, skills, MCP, and local OpenAI-compatible runtimes.

- v2.2.3 (2026-10-30) introduced the built-in Claude Agent provider; v2.2.4 added guided setup; v2.2.6 was released 2026-11-06.
- The release page separately marks v1.19.5 as the general latest release. Pin and test the v2 channel explicitly.
- Current v2 provider configuration documents Anthropic API, OpenAI-compatible custom providers, OpenRouter, and vLLM discovery (`http://127.0.0.1:8000/v1`).
- Agents can define model, system prompt, mode, and permissions; sessions can switch models without rewriting the configuration.
- Claude Agent setup: install Claude Code, run `claude auth login`, then `/connect` → `Claude Agent`.
- Provider ID: `claude-agent`. OpenCode runs the local `claude` executable through Anthropic’s public Agent SDK and does not replay saved OAuth tokens. `OPENCODE_CLAUDE_PATH` selects the executable.
- OpenCode owns tools, permissions, history, skills, agents, compaction, and provider/model switching. Claude Code’s own tools, `CLAUDE.md`, hooks, MCP configuration, auto-memory, teams, cloud sessions, and native plan mode are not inherited.
- Claude Agent requires Claude to be installed/authenticated on the same machine; it is unsuitable for hosted OpenCode or remote workspaces that cannot start local programs.

### Pi Agent

The main alternative for a minimal, highly customizable harness. It may offer lower prompt overhead and a smaller core, but requires more N1-owned integration for permissions, queues, provider setup, and polished workflow UX. It must be evaluated against the same capability matrix rather than judged from general preference reports.

Required checks: provider registry, subscription bridges, OpenAI-compatible/vLLM configuration, subagent isolation, extension API stability, session persistence, cancellation, and noninteractive execution.

### Gateways and bridges

OpenRouter, Meridian, CLIProxyAPI, and similar systems can normalize provider access, accounts, or protocols. They are routing layers, not replacements for the coding-agent harness. They may be useful behind OpenCode or Pi, but add credential, latency, billing, and recovery surfaces.

## 4. Provider options to validate

| Provider option | Expected integration | Key questions |
|---|---|---|
| Codex/ChatGPT subscription | Official OpenAI/Codex sign-in where supported by harness | Does sign-in remain supported in the selected harness? Are unattended/headless limits clear? |
| Anthropic subscription | OpenCode `claude-agent`, Pi official-CLI bridge, or equivalent | Is subscription use authorized for third-party harness automation? Does it work in queues and remote workers? |
| Anthropic API | Native Anthropic provider | Stable production fallback; compare cost, context, and feature behavior. |
| z.ai/GLM subscription/API | Native integration or official CLI/SDK bridge | Confirm account method, automation terms, model/tool compatibility, and freshness. |
| vLLM | OpenAI-compatible `/v1` endpoint; local discovery/configuration | Tool calling, streaming, reasoning fields, context limits, concurrency, auth, and model naming. |
| OpenRouter | Native provider or OpenAI-compatible endpoint | Model routing, provider fallbacks, usage metadata, privacy, retries, and deterministic model selection. |
| Other OpenAI-compatible servers | Custom provider with explicit model declarations | Which request/response quirks require provider-specific configuration? |

No subscription option is considered production-ready until its authentication, policy, refresh, headless behavior, and usage accounting are verified.

## 5. Anthropic/OpenCode findings (checked 2026-11-09)

- Anthropic’s current help page says signed-in Claude plans continue to consume subscription limits through the Claude Agent SDK and `claude -p`.
- Anthropic consumer terms restrict automated/non-human access unless using an API key or an explicitly permitted mechanism. Anthropic does not clearly state that arbitrary third-party harness use of a Claude subscription is authorized.
- Therefore Claude subscription use is technically possible through OpenCode v2 but compliance is ambiguous. Anthropic API/Bedrock/Vertex is the unambiguous production route for unattended N1 automation.
- [Issue #61020](https://github.com/anomalyco/opencode/issues/61020), opened 2026-11-01: Claude Agent model catalog can fall back to a 200k context limit and compact early.
- [Issue #61248](https://github.com/anomalyco/opencode/issues/61248), opened 2026-11-02: plugin-added system instructions may not reach Claude Agent.
- [Issue #62648](https://github.com/anomalyco/opencode/issues/62648), opened 2026-11-07: deleting a session may leave the Claude child process alive for roughly five minutes.
- Verify whether v2.2.6 fixed or exposed model-fallback metadata, prompt-cache behavior, and desktop PATH/authentication issues.

## 6. Community evidence and freshness

Freshness checked 2026-11-09. Stars are adoption signals only, not security, maintenance, or policy guarantees.

- [griffinmartin/opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth): about 1.3k stars, OpenCode v2 support, active late-October issues. OAuth workaround; not the default foundation.
- [openchamber/opencode-claude](https://github.com/openchamber/opencode-claude): 139 stars, v2 releases on 2026-10-30, Claude Agent SDK/CLI approach. Now overlaps with upstream functionality.
- [cemalturkcan/opencode-anthropic-login-via-cli](https://github.com/cemalturkcan/opencode-anthropic-login-via-cli): 137 stars, supports v1/v2 and several login methods. Lower confidence than upstream.
- [dotCipher/opencode-claude-bridge](https://github.com/dotCipher/opencode-claude-bridge): 112 stars, latest listed release 2026-07-02 with later workflow activity. Older bridge architecture.
- [dotCipher/opencode-anthropic-user-agent-plugin](https://github.com/dotCipher/opencode-anthropic-user-agent-plugin): archived 2026-03-23 and superseded; exclude.
- Meridian and CLIProxyAPI remain candidates for separate routing-layer research, not harness selection.

## 7. Working recommendation

1. Evaluate OpenCode v2.2.6 first, including its native Claude Agent, Anthropic API, OpenRouter, and vLLM paths.
2. Evaluate Pi with the same tests, emphasizing extension effort and automation reliability.
3. Prefer native API or officially supported sign-in paths for unattended production.
4. Use subscription bridges only as optional interactive/local integrations until policy and operational behavior are verified.
5. Keep provider selection in configuration/persona metadata so N1 orchestration is not coupled to one vendor SDK.

## 8. Cross-provider acceptance test

Run the same workflow with Claude Agent, Anthropic API, one OpenAI/Codex path, one z.ai/GLM path, vLLM, and OpenRouter where credentials are available:

```text
analysis → read-only research subagent → implementation subagent
→ edit-denied reviewer → persist N1 memory → interrupt → resume
→ delete child session → switch provider/model → continue
```

Record: instruction delivery, plugin/gate delivery, permission enforcement, subagent isolation, tool calls, streaming, context/compaction limits, child-process cleanup, telemetry, retries/fallbacks, cost/usage reporting, model identity, resume duplication, queue behavior, and account/credential handling.

## 9. Deferred checks

- Live authenticated OpenCode v2.2.6 Claude Agent smoke test.
- Live OpenCode Anthropic API, OpenAI/Codex, OpenRouter, and vLLM tests.
- Live Pi comparison using the same acceptance workflow.
- z.ai/GLM subscription/API authentication and automation-policy verification.
- Detailed N1 feature-by-feature migration matrix against OpenCode and Pi extension APIs.
- Adapter boundary design: which state remains N1-owned and which state is delegated to the harness.
- Verification of fixes for the open OpenCode issues above.

## 10. Evidence sources

- [OpenCode v2.2.3 release](https://github.com/anomalyco/opencode/releases/tag/v2.2.3)
- [OpenCode v2.2.6 release](https://github.com/anomalyco/opencode/releases/tag/v2.2.6)
- [Claude Agent provider specification](https://github.com/anomalyco/opencode/blob/dev/specs/v2/claude-agent-provider.md)
- [OpenCode provider documentation](https://docs.opencode.ai/docs/providers/)
- [OpenCode agents documentation](https://opencode.ai/docs/agents)
- [Anthropic: Claude Agent SDK with Claude plans](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
- [Anthropic Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
- [N1 repository README](README.md)
- `~/dev/n1-codex` reference fork (local, to inspect in the migration matrix)

## 11. Investigation log

| Date | Area | Result |
|---|---|---|
| 2026-11-09 | OpenCode v2 / Claude Agent | Built-in provider is the leading Anthropic subscription integration; unresolved context, plugin-hook, and cleanup issues remain. |
| 2026-11-09 | Community bridges | Several active projects exist, but upstream functionality now supersedes most; archived projects excluded. |
| 2026-11-09 | Scope correction | Investigation expanded from Anthropic/OpenCode to full harness selection and provider-switching migration for N1. |

## 12. Update protocol

On each further investigation turn:

1. Re-check release/commit dates, issue activity, and archive status for every recommended harness or bridge.
2. Test or document each provider option separately; do not infer subscription behavior from API behavior.
3. Add only evidence-backed findings with source links and dates.
4. Move resolved items from **Deferred checks** into the relevant verified section.
5. Record changed recommendations explicitly in the investigation log.
6. Update the **Last checked** date and keep this file as the handoff point for the next investigator.
