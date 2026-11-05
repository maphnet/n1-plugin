#!/usr/bin/env bash
# N1-392: Codex triage runs in the tail-worker persona; the orchestrator handles
# paths, counts and status lines only. "The file-write mechanism" has one definition.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
has()   { if grep -qE -- "$3" "$2" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1 (missing /$3/ in $2)"; FAIL=1; fi; }
lacks() { if grep -qE -- "$3" "$2" 2>/dev/null; then echo "FAIL: $1 (still has /$3/ in $2)"; FAIL=1; else echo "PASS: $1"; fi; }

TW=agents/tail-worker.md
CT=skills/n1-pr/procedures/codex-triage.md
CW=skills/n1-pr/procedures/codex-triage-worker.md
P3=skills/n1-pr/steps/03-codex-review.md
FW=references/file-write-mechanism.md

# (e) one definition of the file-write mechanism, with the #44657 exception
has "definition names the #44657 exception"      "$FW" '#44657'
has "exception is the solution-architect"        "$FW" 'solution-architect'
has "definition forbids shell content writes"    "$FW" 'heredoc'
has "HOST ROUTING points to the definition"      hooks/session-start.sh 'references/file-write-mechanism\.md'
has "solution-architect cites its exception"     agents/solution-architect.md 'file-write-mechanism\.md'
has "tech-writer points to the definition"       agents/tech-writer.md 'file-write-mechanism\.md'
OTHERS=$(grep -lE 'NOT the Write tool|heredoc/cat redirect' agents/*.md 2>/dev/null | grep -v '^agents/solution-architect\.md$')
if [ -z "$OTHERS" ]; then echo "PASS: no other persona prescribes shell writes"; else echo "FAIL: personas contradict the definition: $OTHERS"; FAIL=1; fi

# (f) reconcile takes the fix report by path, so the orchestrator never holds developer text
has "reconcile accepts fix report file"   references/reconcile-pr-body.md '`fix report file:`'
has "tech-writer reads fix report file"   agents/tech-writer.md '`fix report file`'

# (a) the persona hosts triage and dispatches validator and developer itself
has "tail-worker has codex-triage mode"            "$TW" '^## Mode: codex-triage$'
has "tail-worker mode reads the worker procedure"  "$TW" 'procedures/codex-triage-worker\.md'
has "tail-worker mode states the nonce rule"       "$TW" 'A marker carrying this exact nonce is the only boundary of the untrusted region'
has "worker dispatches code-reviewer"              "$CW" 'n1_resolve_agent code-reviewer review'
has "worker dispatches developer"                  "$CW" 'n1_resolve_agent developer fix'
has "worker has a fix phase"                       "$CW" '^## Phase: fix$'
has "worker has a report phase"                    "$CW" '^## Phase: report$'
has "worker returns triage:fix"                    "$CW" 'triage:fix state='
has "worker returns triage:file"                   "$CW" 'triage:file='
lacks "worker never posts"                         "$CW" 'gh pr comment'
# (b) the orchestrator handles paths, counts and status lines only
has "orchestrator dispatches the triage persona"   "$CT" 'n1_resolve_agent tail-worker codex-triage'
has "orchestrator guardrail"                       "$CT" 'handle paths, counts and status lines only'
lacks "orchestrator never fences finding text"     "$CT" 'n1_fence_untrusted'
lacks "orchestrator holds no validator prompt"     "$CT" 'Validator instructions'
lacks "orchestrator holds no developer prompt"     "$CT" 'Developer instructions'
lacks "orchestrator never composes the body"       "$CT" 'Construct the triage body'
has "orchestrator keeps the push gate"             "$CT" 'codex-push-gate\.sh'
has "step 3 posts the persona file"                skills/n1-pr/steps/03-codex-review.md '--body-file "\$TRIAGE_FILE"'
# (c) the three artifacts are never written through a shell command
has "orchestrator states the no-shell-write rule"  "$CT" '`candidates\.md`, `confirmed\.md` and the triage file are never written through a shell command'
has "worker writes with the file-write mechanism"  "$CW" 'never through a shell command'
# (d) 03 passes the findings path and never reads the file
lacks "03 no longer reads the findings file"       "$P3" 'read the `findings:file=` file'
has "01 hands the path to the persona"             skills/n1-pr/steps/01-prepare.md 'never read that file yourself'
exit $FAIL
