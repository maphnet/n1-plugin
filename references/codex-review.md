### Codex Cross-Model Review

Optional cross-model review via the OpenAI Codex CLI plugin. Gated on `codex.enabled` in `$N1_HOME/config.json` (default `false`; backward compat reads `codexReview.enabled` via `n1_codex_val` fallback). Single touchpoint:

- **PR review** (Step 7 / `n1-review` Phase 2): `n1_codex_preflight "<BASE_BRANCH>"` check (availability + branch resolution), then `codex-reviewer` agent (spawned via Agent tool) runs the Codex CLI directly, retries on failure, and parses output into `[CX-N]`-prefixed structured findings merged into `review.md` alongside `[CR-N]` and `[SEC-N]`.

Codex is not used for plan review (Step 4b) — the CCR solution-architect with codebase access (Grep/Read) is strictly more capable for assumption validation than a text-only Codex `task` call.

**Config keys** (in `codex` block, backward compat for `codexReview` block):
- `codex.enabled` (boolean, default `false`) — master gate for all Codex touchpoints.
- `codex.model` (string, optional) — omit to inherit Codex CLI default. Passed as `--model` to all invocations.

**Helpers** (in `lib/config.sh`):
- `n1_codex_val <key>` — reads `.codex.<key>` first, falls back to `.codexReview.<key>`.
- `n1_codex_available` — 2-step probe: enabled check + CLI availability. Returns 0 on success, 1 on failure.
- `n1_codex_preflight <base_branch>` — wraps `n1_codex_available` + verifies the base branch ref resolves via `git rev-parse --verify`. Returns diagnostic on stderr on failure.

**CLI Invocation:**

The `codex-reviewer` agent invokes the Codex CLI directly using the `codex review` subcommand:

```bash
codex review --base <BASE_SHA> [--instructions "<prior_findings>"] 2>&1
```

- `--base <BASE_SHA>` — restricts review to commits reachable from HEAD but not from the base SHA. Used on cycle 1 (full branch diff) and on the final full-branch pass after delta re-review converges.
- `--commit <HEAD_SHA>` — restricts review to a single commit. Used on delta re-review passes (cycles ≥ 2) to focus Codex on what the developer changed in the latest fix cycle, avoiding re-flagging already-addressed findings.
- `--instructions "<prior_findings>"` — carries a summary of prior-cycle confirmed Critical/High findings into the prompt so Codex can check whether they were actually resolved. **Feature-detected at runtime:** the `codex-reviewer` agent probes whether the installed `codex` binary accepts `--instructions` by running `codex review --help` and checking for the flag before using it. If absent, the flag is omitted and prior findings are not injected.

Note: `codex-companion.mjs` functions are retained in `lib/config.sh` for backward compatibility with external callers, but are no longer used internally.

**Delta Re-Review Behavior:**

- **Cycle 1:** Full branch diff — `codex review --base <REVIEW_BASE>`.
- **Cycles ≥ 2 (delta):** Single-commit review — `codex review --commit <HEAD_SHA>` with `--instructions` carrying prior confirmed findings (if supported). Focuses Codex on the fix rather than the entire branch.
- **Final full-branch pass:** After a delta pass produces a clean result (no Critical/High), one additional `codex review --base <REVIEW_BASE>` pass is required to confirm the entire branch is clean before emitting final PASS.

**Fingerprint-Based Convergence Detection:**

After each review cycle, every confirmed Critical/High finding is fingerprinted by file path + normalized title and recorded in `$N1_HOME/memory/<ID>/fingerprints.jsonl` via `n1_fingerprint_append`. Before spawning the developer for the next cycle, `n1_fingerprint_check_convergence` compares the current blocking count against the previous cycle's count:

- If the blocking count decreased → allow another fix cycle.
- If the blocking count did NOT decrease (stayed the same or increased) → escalate immediately rather than burning remaining cycles.

Escalation message: "Review findings are not converging (blocking count: \<prev\> → \<new\>). Continuing fix cycles is unlikely to resolve the remaining issues."

Maximum 3 review-fix cycles (`review.maxFixAttempts`, configurable); on exhaustion the same escalation protocol applies.

**Severity Mapping:**

Codex CLI reports findings with P0–P3 priority labels. N1 maps these to its four-tier scale:

| Codex | N1 |
|-------|----|
| P0 | Critical |
| P1 | High |
| P2 | Medium |
| P3 | Low |

**Keyword fallback:** If a finding carries no P-label, the `codex-reviewer` agent applies keyword matching against the finding title to infer severity (e.g., "injection", "XSS", "RCE" → Critical; "null pointer", "race condition" → High; etc.). Unclassified findings default to Medium.

**Changed-hunk scoping:** The `codex-reviewer` agent cross-references each finding's file:line against the diff hunk map. Findings outside changed hunks are downgraded one tier (they may be pre-existing issues unrelated to this PR) and annotated `[pre-existing?]`.

**Fix-the-Class Directive:**

When the confirmed Critical/High findings include any `[SEC-N]` finding, or any `[CX-N]` finding whose title contains a security keyword (injection, XSS, CSRF, authentication, authorization, traversal, deserialization, command execution, SSRF, open redirect, SQL injection, path traversal, RCE), the orchestrator appends a fix-the-class directive to the developer spawn prompt:

> "One or more findings are security-shaped. When fixing a security finding, do NOT fix only the specific instance reported. Instead, fix the entire CLASS of the vulnerability: search the codebase for all variants of the same pattern (e.g., all injection points, all unsanitized inputs of the same type, all instances of the same auth bypass pattern) and fix them all in one pass. This prevents variant whack-a-mole where fixing one instance exposes the next variant in the subsequent review cycle."

This directive is injected in both the `n1-start` fix step and the `n1-review` Phase 4 developer spawn.

**Availability gate:** `n1_codex_preflight` encapsulates the full probe (enabled + CLI + base branch resolution). If any check fails, the step logs a skip note with the specific reason and proceeds Claude-only — Codex is a soft/optional dependency with no `.claude-plugin/plugin.json` entry.

**Partial-failure handling:** a failed Codex call (non-zero exit or empty output), handled inside the `codex-reviewer` agent, is retried once, then the review proceeds with the remaining reviewers and records the gap with **actual stderr** (first 20 lines, verbatim — no model interpretation). Empty stdout with exit 0 is treated as a failure. A missing Codex reviewer is never treated as a PASS.

**Codex-aware review delegation (v2.11.0):** When Codex is active (enabled, available, and the diff is not doc/config-only), Codex owns whole-diff general correctness and the Claude `code-reviewer` narrows to Test Quality `[TQ-N]` + design-intent only; when Codex is inactive, `code-reviewer` reverts to full scope. `security-reviewer` and Codex are gated by diff surface: doc/config-only diffs skip both (code-reviewer still runs), and `security-reviewer` runs only on security-relevant diffs (biased to run when uncertain). Every skipped reviewer is recorded in `review.md`. Applies to both `n1-start` Step 7 and `n1-review` Phase 2.

**CCR vs Superpowers spec review (N1-42 investigation):** The plan-review CCR step and Superpowers spec review serve complementary purposes. CCR validates the *implementation plan* against codebase reality (assumption checking, scope drift, ordering risks, blast radius) — it reads actual source files via Grep/Read. Superpowers spec review validates the *design spec* against user intent (completeness, consistency, ambiguity). Both are retained.
