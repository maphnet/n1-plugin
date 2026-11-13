# Review: incremental re-review (cycle >= 1)

Read from `steps/review.md` when `INCREMENTAL=true`; `INCREMENTAL` and `FIX_FILES` were printed by its first fence (printed values, not shell variables).

`INCREMENTAL=true`: pass code-reviewer `$N1_HOME/memory/$ID/fix.diff` path and `<printed FIX_FILES>` as file scope; instruct "Incremental re-review — review only the changes in fix.diff, read surrounding code only as needed; check regressions; verify all prior findings addressed (review-prev.md: re-report unfixed by id)." The security-reviewer gets the same fix.diff path and `<printed FIX_FILES>` plus the prior `[SEC-N]` list from review-prev.md: re-verify by id, re-report unfixed (they FAIL); new findings only as regressions from fix.diff.

A fix cycle that only disputed findings has an empty fix.diff and is still incremental: rule on the disputes. Number a new finding above the highest ID in review-prev.md; never reuse a prior ID for a different defect.

Both reviewers also return one status line per prior blocking ID they own and rule on the developer's `disputed` lines: `procedures/review-fix-budget.md § Status lines` and § Disputes. Pass each the `$N1_HOME/memory/$ID/implementation.md` path and the heading `## Fix Cycle <printed CYCLE>`. After all reviewers return, write every status line verbatim to `$N1_HOME/memory/$ID/review-status.md` with the file-write mechanism (no lines: an empty file) before the collect block; never put reviewer text in a shell command.
