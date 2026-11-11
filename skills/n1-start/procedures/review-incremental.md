# Review: incremental re-review (cycle >= 1)

Read from `steps/review.md` when `INCREMENTAL=true`; `INCREMENTAL` and `FIX_FILES` were printed by its first fence (printed values, not shell variables).

`INCREMENTAL=true`: pass code-reviewer `$N1_HOME/memory/$ID/fix.diff` path and `<printed FIX_FILES>` as file scope; instruct "Incremental re-review — review only the changes in fix.diff, read surrounding code only as needed; check regressions; verify all prior findings addressed (review-prev.md: re-report unfixed by id)." The security-reviewer gets the same fix.diff path and `<printed FIX_FILES>` plus the prior `[SEC-N]` list from review-prev.md: re-verify by id, re-report unfixed (they FAIL); new findings only as regressions from fix.diff.
