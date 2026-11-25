#!/usr/bin/env bash
# N1-640: persona and skill text must not instruct tool calls the persona cannot make,
# and must state required arguments for deferred tools that were called with wrong ones.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
has() { if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1"; fi; }    # <label> <fixed string> <file>
hasnt() { if grep -qE -- "$2" "$3"; then fail "$1"; else pass "$1"; fi; }  # <label> <ERE> <file>

# Class 1: code-reviewer has no Bash; it reads change facts from the dispatch prompt.
hasnt "code-reviewer instructs no git command" 'git (diff|status|ls-files)' agents/code-reviewer.md
has "code-reviewer reads CHANGED_STATUS from the prompt" 'CHANGED_STATUS:' agents/code-reviewer.md
has "code-reviewer reads UNTRACKED from the prompt" 'UNTRACKED:' agents/code-reviewer.md
has "code-reviewer no-diff stop keys on NO_DIFF=true" 'NO_DIFF=true' agents/code-reviewer.md
has "code-reviewer tools unchanged (no Bash)" 'tools: Read, Grep, Glob, Write' agents/code-reviewer.md
has "review-core prints NO_DIFF" 'echo "NO_DIFF=${NO_DIFF}"' skills/n1-start/review-core.md
has "review-core prints CHANGED_STATUS" 'echo "CHANGED_STATUS:"' skills/n1-start/review-core.md
has "review-core prints UNTRACKED" 'echo "UNTRACKED:"' skills/n1-start/review-core.md
has "review-core writes full diff for code-reviewer" 'echo "CODE_DIFF=${CODE_DIFF}"' skills/n1-start/review-core.md
has "code-reviewer reads CODE_DIFF" 'CODE_DIFF=' agents/code-reviewer.md
hasnt "review-core change facts are not capped" '(CHANGED_STATUS|UNTRACKED)=.*head -n' skills/n1-start/review-core.md
has "review-core change facts include working tree" 'git diff --name-status "$BASE")' skills/n1-start/review-core.md
for f in skills/n1-start/steps/review.md skills/n1-review/steps/01-analyze.md skills/n1-start/procedures/review-incremental.md skills/n1-pr/steps/02-push-create.md; do
    has "code-reviewer dispatch passes NO_DIFF: $f" 'NO_DIFF' "$f"
done
hasnt "n1-start review no longer passes only diff --name-only" 'diff `--name-only`' skills/n1-start/steps/review.md

# Class 2: personas with Bash list no Grep/Glob and tell the model to search via Bash.
for p in developer qa-engineer tech-writer local-test-planner; do
    hasnt "$p tools list has no Grep/Glob" '^tools:.*(Grep|Glob)' "agents/$p.md"
    has "$p keeps Bash" 'Bash' "agents/$p.md"
done
for p in developer qa-engineer tech-writer solution-architect; do
    hasnt "$p text names no Grep/Glob tool" 'Use (Grep|Glob)|Grep for searching' "agents/$p.md"
    has "$p searches via Bash" 'via Bash' "agents/$p.md"
done
has "security-reviewer keeps Grep (no Bash)" 'tools: Read, Grep, Glob, Write' agents/security-reviewer.md

# Class 3/4: subagents get no session routing; personas that call deferred tools carry the rules.
for p in product-analyst pr-worker tail-worker ci-worker local-testing-worker; do
    has "$p loads deferred tool schemas first" 'before its first call' "agents/$p.md"
    hasnt "$p names no host-only tool" 'ToolSearch' "agents/$p.md"
done
for p in pr-worker tail-worker ci-worker local-testing-worker; do
    has "$p states Monitor required args" 'Monitor requires both `command` and `description`' "agents/$p.md"
done
has "product-analyst scopes cloudId to the Atlassian MCP" 'For jc-mcp: pass `issueKey` only' agents/product-analyst.md

# --- end of checks ---
exit "$FAIL"
