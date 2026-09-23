<!-- Purpose: Optional cross-host review via Codex CLI after PR creation (Step 9). Claude Code -> Codex direction only. -->

## Step 9: Cross-Host Review (optional)

Skip this step entirely (no output) when ANY of these conditions is true:
- `N1_HEADLESS` is `1` AND `crossHostReview.autoTriage` is not `true` in config
- PR URL is not available from prior steps
- Host is not `claude-code` (check via bash snippet below)
- `crossHostReview.enabled` is explicitly `false` in config (default: `true` when absent)
- `codex` CLI is not installed (`command -v codex` fails)
- Codex auth is not available (`codex login status` exits non-zero)

### Gate checks

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/host.sh"
source "$N1_ROOT/lib/config.sh"
N1_HOME=$(n1_home)

HOST=$(n1_host)

# NOTE: n1_config_val uses jq `// empty` which treats boolean false as falsy,
# returning empty for both absent AND false. Use the null-check pattern instead
# (same as n1_plan_review_enabled and n1_ci_checks_val in lib/config.sh).
N1_CONFIG="$N1_HOME/config.json"
if [ -f "$N1_CONFIG" ] && command -v jq >/dev/null 2>&1; then
  GATE=$(jq -r 'if .crossHostReview.enabled == null then "absent" else (.crossHostReview.enabled | tostring) end' "$N1_CONFIG" 2>/dev/null || echo "absent")
  AUTO_TRIAGE=$(jq -r 'if .crossHostReview.autoTriage == true then "true" else "false" end' "$N1_CONFIG" 2>/dev/null || echo "false")
else
  GATE="absent"
  AUTO_TRIAGE="false"
fi
# absent = default true (opt-out model); any other value is taken literally
[ "$GATE" = "absent" ] && GATE="true"
echo "host=$HOST"
echo "crossHostReview_enabled=$GATE"
echo "crossHostReview_autoTriage=$AUTO_TRIAGE"
echo "codex_installed=$(command -v codex >/dev/null 2>&1 && echo yes || echo no)"
echo "headless=${N1_HEADLESS:-0}"
```

If `host` is not `claude-code`, skip silently.
If `crossHostReview_enabled` is `false`, skip silently.
If `codex_installed` is `no`, skip silently.
If `headless` is `1` AND `crossHostReview_autoTriage` is NOT `true`, skip silently.
If `headless` is `1` AND `crossHostReview_autoTriage` is `true`, skip the interactive prompt but continue to the Dispatch section (triage mode — the Codex review runs automatically, and findings are triaged after posting).

Auth check (only if above checks pass):

```bash
if codex login status >/dev/null 2>&1; then
  echo "codex_auth=yes"
else
  echo "codex_auth=no"
fi
```

If `codex_auth` is `no`, skip silently.

### Prompt

All checks passed.

**Autonomy gate:**

```bash
source ~/.n1/preamble.sh
MECHANICAL=$(n1_autonomy_val 'mechanicalPrompts')
echo "mechanical=$MECHANICAL"
```

If `mechanical` is `auto`:

Check whether unattended execution is explicitly permitted:

```bash
source ~/.n1/preamble.sh
N1_CONFIG="$N1_HOME/config.json"
if [ -f "$N1_CONFIG" ] && command -v jq >/dev/null 2>&1; then
  ALLOW_UNATTENDED=$(jq -r 'if .crossHostReview.allowUnattended == true then "true" else "false" end' "$N1_CONFIG" 2>/dev/null || echo "false")
else
  ALLOW_UNATTENDED="false"
fi
echo "allow_unattended=$ALLOW_UNATTENDED"
```

If `allow_unattended` is `false`: skip the review silently and continue the pipeline. The `--dangerously-bypass-approvals-and-sandbox` flag required for unattended execution is not enabled by default; set `crossHostReview.allowUnattended: true` in config to opt in.

If `allow_unattended` is `true`: skip the user prompt, proceed with the review automatically, and append a Decision Ledger row inside the `## Decision Ledger` table in `$N1_HOME/memory/$ID/overview.md` (insert before the next `##` section; create the table if absent):

```
| pr | cross-host-review | B | [auto] | Cross-host Codex review: auto-triggered in hands-off mode | yes | — | autonomy.mechanicalPrompts=auto + crossHostReview.allowUnattended=true | --- |
```

Otherwise: ask the user:

> Codex CLI is available. Would you like a cross-host review of this PR? (yes/no)

If the user declines, continue the pipeline silently.

### Dispatch

If the user accepts **or** (`mechanical` is `auto` and `allow_unattended` is `true`):

```bash
PR_NUMBER="<the PR number from step 4>"
PR_URL="<the PR URL from step 4>"

# -o writes only the final agent message to a file; stdout gets the full session
# transcript (hooks, tool calls, reasoning) which can be 100s of KB — discard it.
CODEX_STDERR=$(mktemp)
CODEX_OUTPUT_FILE=$(mktemp)
codex exec "Review PR ${PR_URL} for correctness, code quality, and potential bugs. Focus on logic errors, edge cases, and maintainability. Output your findings as a structured list." \
  --dangerously-bypass-approvals-and-sandbox \
  -o "$CODEX_OUTPUT_FILE" \
  2>"$CODEX_STDERR" >/dev/null
CODEX_RC=$?
CODEX_OUTPUT=$(<"$CODEX_OUTPUT_FILE")
rm -f "$CODEX_STDERR" "$CODEX_OUTPUT_FILE"
```

Parse `CODEX_OUTPUT`. If `CODEX_RC` is non-zero or `CODEX_OUTPUT` is empty, warn inline ("Codex review did not produce output or failed") and continue the pipeline.

### Post findings

If `CODEX_OUTPUT` is non-empty, post as a PR comment. Pipe via stdin using `--body-file -` to prevent shell expansion of Codex output. Post as rendered markdown — Codex output is already markdown-structured:

```bash
# Pipe body via stdin to avoid shell interpolation of CODEX_OUTPUT.
printf '## Cross-Host Review (Codex)\n\n%s\n' "$CODEX_OUTPUT" | \
  gh pr comment "$PR_NUMBER" --body-file -
```

If `gh pr comment` fails, write findings to `$N1_HOME/memory/<ID>/cross-host-review.md` as fallback and warn inline.

Report result:
```
Cross-host review: posted as PR comment (or: written to memory as fallback)
```

### Triage Gate

If `crossHostReview_autoTriage` is NOT `true`, stop here (current behavior — findings posted, no triage).

If `crossHostReview_autoTriage` is `true`, continue to severity parsing.

### Severity Parsing

Parse `CODEX_OUTPUT` for severity markers. This is best-effort — Codex output format is not standardized. The safe default when parsing fails is to route all findings to human review.

```bash
source ~/.n1/preamble.sh

MAX_FIX_ATTEMPTS=$(n1_cross_host_review_val 'maxFixAttempts')
echo "maxFixAttempts=$MAX_FIX_ATTEMPTS"
```

Scan `CODEX_OUTPUT` for severity indicators. Look for patterns (case-insensitive): `Critical`, `High`, `Medium`, `Low`, as well as formatted variants like `**High**`, `### High`, `[HIGH]`, `Severity: High`.

Classify findings into two groups:
- **High+ findings** (Critical or High severity) — candidates for auto-fix
- **Human-review findings** (Medium, Low, or unclassified) — flagged for human review

If zero severity markers are found in the entire output, treat ALL findings as unclassified and route to human review. Skip the fix cycle and proceed directly to the triage reply.

### Fix Cycle

If there are no High+ findings, skip to Triage Reply.

> **ORCHESTRATOR GUARDRAIL (cross-host-triage): the orchestrator NEVER edits files, runs formatters, linters, or commits in this section. Every remediation goes through the developer spawn below.**

Resolve model for developer:

```bash
source ~/.n1/preamble.sh
IFS=$'\t' read -r DEVELOPER_MODEL DEVELOPER_EFFORT < <(n1_resolve_agent developer fix)
```

Dispatch developer with `$DEVELOPER_MODEL` and `$DEVELOPER_EFFORT`. Pass:
- The extracted High+ findings (verbatim text from Codex output)
- PR branch name
- Current working directory (worktree or checkout path)
- Memory files (`plan.md`, `implementation.md`) if available at `$N1_HOME/memory/$ID/`

**Developer instructions:**

```
You are fixing cross-host review findings on an open pull request.

Workspace: resolve your working directory:
- If `<worktree path>` exists, work there.
- Otherwise, in `<main checkout path>`: `git fetch origin <branch> && git checkout <branch>`.
Never work on the default branch.

Findings to fix:
<HIGH_PLUS_FINDINGS>

For each finding:
1. Identify the relevant code in the codebase
2. Implement the minimal fix
3. If the finding is not actionable or is a false positive, report it as DISMISSED with reasoning

Commit all fixes with descriptive messages. Push to the PR branch.

Output format:
## Cross-Host Review Fixes
### Finding: <summary>
- **Action:** Fixed | Dismissed
- **Detail:** <what was changed or why dismissed>
- **Files:** <modified files>
## Summary
- Fixed: N
- Dismissed: M
```

**Wait for the developer persona to return its result before proceeding.**

After developer returns:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/frontmatter.sh"
n1_increment_counter "$N1_HOME/memory/$ID/overview.md" "cross_host_fix_cycle"
```

If `cross_host_fix_cycle` >= `maxFixAttempts`, proceed to Triage Reply with remaining unfixed findings routed to human review. Do NOT retry — default `maxFixAttempts=1` means a single pass.

If the developer dispatch fails (error, timeout, empty output), log warning inline and route all High+ findings to human review. Do not block the pipeline.

### Triage Reply

Post a follow-up PR comment summarizing the triage outcome. This is a NEW comment (not an edit of the original review comment).

Construct the triage body from:
- **Auto-Fixed** — findings the developer successfully fixed (from developer output, action=Fixed)
- **Dismissed** — findings the developer evaluated and dismissed as false positives (from developer output, action=Dismissed)
- **For Human Review** — Medium/Low findings + any High+ findings the developer could not fix + all unclassified findings
- **Summary** — "N findings triaged: X auto-fixed, Y dismissed, Z for human review"

Omit any section that has zero items (e.g., if nothing was auto-fixed, omit the Auto-Fixed section).

```bash
# TRIAGE_BODY is constructed by the model from the parsed results above.
# Post as rendered markdown via stdin.
printf '## Cross-Host Review Triage\n\n%s\n' "$TRIAGE_BODY" | \
  gh pr comment "$PR_NUMBER" --body-file -
```

If `gh pr comment` fails, write triage summary to `$N1_HOME/memory/$ID/cross-host-triage.md` as fallback and warn inline.

Report result:
```
Cross-host triage: posted as PR comment (or: written to memory as fallback)
Summary: N findings triaged — X auto-fixed, Y dismissed, Z for human review
```
