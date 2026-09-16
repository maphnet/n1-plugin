<!-- Purpose: Optional cross-host review via Codex CLI after PR creation (Step 9). Claude Code -> Codex direction only. -->

## Step 9: Cross-Host Review (optional)

Skip this step entirely (no output) when ANY of these conditions is true:
- `N1_HEADLESS` is `1`
- PR URL is not available from prior steps
- Host is not `claude-code` (check via bash snippet below)
- `crossHostReview.enabled` is explicitly `false` in config (default: `true` when absent)
- `codex` CLI is not installed (`command -v codex` fails)
- Codex auth is not available (`codex login status` exits non-zero)

### Gate checks

```bash
N1_ROOT="${CLAUDE_PLUGIN_ROOT:-${PLUGIN_ROOT:-}}"; [ -d "$N1_ROOT/lib" ] || N1_ROOT=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.n1/host.json")))["pluginRoot"])')
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
else
  GATE="absent"
fi
# absent = default true (opt-out model); any other value is taken literally
[ "$GATE" = "absent" ] && GATE="true"

echo "host=$HOST"
echo "crossHostReview_enabled=$GATE"
echo "codex_installed=$(command -v codex >/dev/null 2>&1 && echo yes || echo no)"
echo "headless=${N1_HEADLESS:-0}"
```

If `host` is not `claude-code`, skip silently.
If `crossHostReview_enabled` is `false`, skip silently.
If `codex_installed` is `no`, skip silently.
If `headless` is `1`, skip silently.

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

All checks passed. Ask the user:

> Codex CLI is available. Would you like a cross-host review of this PR? (yes/no)

If the user declines, continue the pipeline silently.

### Dispatch

If the user accepts:

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

If `CODEX_OUTPUT` is non-empty, post as a PR comment. Pipe via stdin using `--body-file -` to prevent shell expansion of untrusted Codex output. Wrap in a fenced code block to prevent Markdown injection:

```bash
# Pipe body via stdin to avoid shell interpolation of untrusted CODEX_OUTPUT.
# Fenced code block prevents Markdown rendering of attacker-influenced content.
printf '## Cross-Host Review (Codex)\n\n```text\n%s\n```\n' "$CODEX_OUTPUT" | \
  gh pr comment "$PR_NUMBER" --body-file -
```

If `gh pr comment` fails, write findings to `$N1_HOME/memory/<ID>/cross-host-review.md` as fallback and warn inline.

Report result:
```
Cross-host review: posted as PR comment (or: written to memory as fallback)
```
