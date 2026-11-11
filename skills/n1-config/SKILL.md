---
name: n1-config
description: "Set up dev-environment access for agents: writes $N1_HOME/dev-access.md (dev URL or entry point, non-secret setup, allowed commands, dev observability selectors) and turns finishWork.postDeployVerification.enabled on or off. Re-run to update in place. Usage: /n1:n1-config"
model: sonnet
effort: low
---

# N1 Config: Dev-Environment Access

## Overview

Collects what agents need to test on the development environment and turns post-deploy verification on or off. It writes two things only:
- `$N1_HOME/dev-access.md`: read by the post-deploy-verifier persona (n1-finish Step 3b) and by n1-release-test.
- `finishWork.postDeployVerification.enabled` (JSON boolean) in the project config. n1-finish gates verification on it through `n1_post_deploy_verification_enabled`; an absent key keeps the legacy smoke fallback (`localTesting.mode: "smoke"`).

Never request or store secrets (passwords, tokens, API keys, private keys, session cookies). The file records where a secret lives, never the secret.

Interactive only: the pipeline never runs this skill.

**Announce at start:** "I'm using the n1-config skill to set up dev-environment access."

**UX rules:**
- Ask one question at a time and wait for the answer.
- Choice questions offer numbered options so the user can answer with a number; option lists follow `references/question-format.md`.

## N1_HOME Resolution

```bash
source ~/.n1/preamble.sh
[ -n "$N1_HOME" ] && echo "N1_HOME=$N1_HOME" || echo N1_NOT_CONFIGURED
```

If the output shows `N1_NOT_CONFIGURED` → "N1 is not configured. Run `/n1:n1-init` first." **STOP.**

## Steps

1. **Dev access**: read current state, enable question, field questions, observability selectors, write `dev-access.md` and the flag, summary
   Read `<N1_ROOT>/skills/n1-config/steps/01-dev-access.md`
