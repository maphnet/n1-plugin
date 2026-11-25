
```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/worker-step.sh"
n1_step_begin "ci" 13
PR="<PR number from the PR creation step; empty when prMode is skip>"
if [[ "$PR" =~ ^[0-9]+$ ]]; then n1_sw_entry ci "$PR"; else echo "ci-worker:no-pr"; fi
```

**If `prMode` is `"skip"`**: no PR; skip ci gate/n1-ci; run the end block with `skipped`; continue.

**Otherwise:** when the fence printed a `model:` line, read `procedures/step-worker-dispatch.md` and follow § Dispatch with persona `ci-worker`, then § ci; when it printed `ci-worker:no-pr`, go straight to the inline fallback below. The worker runs n1-ci (watch, fix loop, push) in a fresh context; the Result fence ends this step. On § Inline fallback, invoke skill `n1:n1-ci` inline with the PR number, then map its result and run the end block. The end block runs only for the prMode skip or after the inline fallback, never after a worker result:
- All checks passed (with or without fixes) → `success` (no checks configured: `skipped`), then continue to FINALIZE
- User chose "skip" (CI still red) → `failed`, continue to FINALIZE with CI status noted
- User is still providing guidance → wait (n1-ci handles the interaction)

```bash
source ~/.n1/preamble.sh
n1_step_end "ci" 13 "<success|failed|skipped>"
```

> **After the ci step ends, IMMEDIATELY continue to the next pipeline step (finish if enabled, otherwise FINALIZE MEMORY) -- do NOT write a summary message or yield to the user. (Orchestrator-only: a fork ignores this.)**
