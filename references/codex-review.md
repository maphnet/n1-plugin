### Codex Cross-Model Review

Optional cross-model review via the OpenAI Codex CLI plugin. Gated on `codex.enabled` in `$N1_HOME/config.json` (default `false`; backward compat reads `codexReview.enabled` via `n1_codex_val` fallback). Single touchpoint:

- **PR review** (Step 7 / `n1-review` Phase 2): `n1_codex_preflight "<BASE_BRANCH>"` check (availability + branch resolution), then `node "$CODEX" review --wait --scope branch --base <branch> [--model] --effort <effort|medium>` with stderr capture and empty-output validation. `codex-adapter` agent parses output into `[CX-N]`-prefixed structured findings merged into `review.md` alongside `[CR-N]` and `[SEC-N]`.

Codex is not used for plan review (Step 4b) — the CCR solution-architect with codebase access (Grep/Read) is strictly more capable for assumption validation than a text-only Codex `task` call.

**Config keys** (in `codex` block, backward compat for `codexReview` block):
- `codex.enabled` (boolean, default `false`) — master gate for all Codex touchpoints.
- `codex.model` (string, optional) — omit to inherit Codex CLI default. Passed as `--model` to all invocations.
- `codex.effort` (string, default `"medium"`) — passed as `--effort` to all invocations.

**Helpers** (in `lib/config.sh`):
- `n1_codex_val <key>` — reads `.codex.<key>` first, falls back to `.codexReview.<key>`.
- `n1_codex_available` — 3-step probe: enabled check + companion path + CLI version. Sets `CODEX` on success.
- `n1_codex_preflight <base_branch>` — wraps `n1_codex_available` + verifies the base branch ref resolves via `git rev-parse --verify`. Returns diagnostic on stderr on failure.

- **Companion resolution:** the Codex plugin ships a `codex-companion.mjs` runtime under its plugin cache. The `n1_codex_companion()` helper in `lib/config.sh` globs `${HOME}/.claude/plugins/cache/*/codex/*/scripts/codex-companion.mjs`, filters to existing files, and returns the newest by version (`sort -V`). Direct companion invocation (`node "$CODEX" review ...`) is used instead of the `/codex:review` slash command because that command is marked `disable-model-invocation: true` and cannot be triggered programmatically.
- **Availability gate:** `n1_codex_preflight` encapsulates the full probe (enabled + companion + CLI + base branch resolution). If any check fails, the step logs a skip note with the specific reason and proceeds Claude-only — Codex is a soft/optional dependency with no `.claude-plugin/plugin.json` entry.
- **Partial-failure handling:** a failed Codex call (non-zero exit or empty output) is retried once, then the review proceeds with the remaining reviewers and records the gap with **actual stderr** (first 20 lines, verbatim — no model interpretation). Empty stdout with exit 0 is treated as a failure. A missing Codex reviewer is never treated as a PASS.
- **Codex-aware review delegation (v2.11.0):** When Codex is active (enabled, available, and the diff is not doc/config-only), Codex owns whole-diff general correctness and the Claude `code-reviewer` narrows to Test Quality `[TQ-N]` + design-intent only; when Codex is inactive, `code-reviewer` reverts to full scope. `security-reviewer` and Codex are gated by diff surface: doc/config-only diffs skip both (code-reviewer still runs), and `security-reviewer` runs only on security-relevant diffs (biased to run when uncertain). Every skipped reviewer is recorded in `review.md`. Applies to both `n1-start` Step 7 and `n1-review` Phase 2.

**CCR vs brainstorm spec review (N1-42 investigation):** The plan-review CCR step and brainstorm spec review serve complementary purposes. CCR validates the *implementation plan* against codebase reality (assumption checking, scope drift, ordering risks, blast radius) — it reads actual source files via Grep/Read. Brainstorm spec review validates the *design spec* against user intent (completeness, consistency, ambiguity). Both are retained.

### Cross-Host PR Review (v3.12.0)

Optional post-PR review dispatched via `codex exec` after PR creation in the n1-pr pipeline. Claude Code -> Codex direction only (v1).

**Trigger conditions** (all must be true):
1. `crossHostReview.enabled != false` (default `true`; opt-out)
2. Host is `claude-code` (via `n1_host()`)
3. `codex` CLI is installed and authenticated at runtime (`codex login status` exits zero)
4. `N1_HEADLESS != 1`
5. PR URL is available from prior step

When triggered: prompts the user, then runs `codex exec` and posts findings via `gh pr comment`. On failure, findings fall back to `$N1_HOME/memory/<ID>/cross-host-review.md`.

**Config key** (in `crossHostReview` block):
- `crossHostReview.enabled` (boolean, default `true`) -- master gate. Set to `false` to suppress the prompt entirely.
