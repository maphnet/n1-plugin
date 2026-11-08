# Review: pre-existing security findings

Read from `steps/review.md` after the reviewers return and the tree freeze passes, before writing review-hdr.md and before routing.

**Pre-existing** (PASS or FAIL, before routing): a `[SEC-N]` whose Index title ends ` (pre-existing)` is not fixed in this run; any other `[SEC-N]` is in-diff, and so is a marked one whose `file:line` lies in a changed hunk or in a file the diff adds (decide before writing review-hdr.md, so verdict and routing agree: run the fixed snippet below in the worktree, no pathspec, never put a finding path or title in a command; non-zero exit or empty output: no diff, every marked `[SEC-N]` counts as in-diff (no downgrade); match `file:line` in-model, an added file shows `--- /dev/null`; a missing or unparsable `file:line` counts as in-diff; note the downgrade in the ledger). Skip a finding whose title is already in `## Follow-ups`. Medium/Low: append to `## Follow-ups` per `<N1_ROOT>/references/followup-filing.md` § Append (source `review`). Critical/High or any other or unparsed severity: § Autonomy Gate (step=`review`; security, so it asks; format: `<N1_ROOT>/references/question-format.md`). 1. Fix now (Recommended): treat as in-diff (FAIL → Step 8); NIST SP 800-218 RV.2 (https://csrc.nist.gov/pubs/sp/800/218/final) says to remediate vulnerabilities in accordance with risk to shorten the attacker's window, and Critical/High carry the highest risk. 2. File as follow-up (§ Append) and proceed: works when the fix lies outside what this run can change safely or needs an owner's decision.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/review-step.sh"
n1_review_preexisting_diff
```
