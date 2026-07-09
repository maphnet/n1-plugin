
**Context discipline — resolve `prMode` (below) BEFORE opening any memory file:**
- `skip` mode reads overview.md only. Do NOT read `review.md`, `qa.md`, `implementation.md`, or `local-testing.md` — the skip path needs only a checkbox update and a report line.
- `draft`/`ready` mode: do not read full reports in this session either — n1-pr extracts the verdict lines it needs via `grep`, and the tech-writer reads the full files itself via the paths it receives.

Resolve `prMode` from `$N1_HOME/config.json` using the fallback chain:
1. If `git.prMode` is present → use it (`"draft"`, `"ready"`, or `"skip"`)
2. Else if `git.draftPR` is `false` → treat as `"ready"`
3. Otherwise → treat as `"draft"`

**If `prMode` is `"skip"`:**
- Do NOT invoke n1-pr
- Do NOT push the branch
- Update `overview.md`: check `[x] PR`, set `step: pr`, add key decision: `"PR: skipped (prMode: skip)"`
- Report: "PR step skipped. Branch `<branch-name>` is ready — merge manually when done."
- Skip Step 11 (CI watch) — no PR to monitor
- Proceed to FINALIZE MEMORY

**Otherwise:** invoke n1-pr as below.

**REQUIRED SUB-SKILL:** Use n1:n1-pr to create the pull request.

Pass to n1-pr:
- `docUpdateMode: "autonomous"` — doc updates run without user confirmation in the full pipeline

The PR skill handles documentation update, tech-writer spawning, git push, PR creation, and tracker update.

After PR is created:
- The PR skill reports the URL

**CHECKPOINT:** "PR created at <URL>. Ready for Tech Lead review."

<!-- AUDIT N1-37: stop after n1:n1-pr is intentional — this is the Tech Lead review checkpoint. Do NOT add a continuation directive here. -->
