
```bash
source ~/.n1/preamble.sh
n1_step_begin "finish" 14; n1_step_end "finish" 14 success
```

**Finish.** Do not merge outside the fullAuto chain at the end of FINALIZE MEMORY; unless it will run, tell the user "Merge the PR (skip if `finishWork.mergeOnFinish: true`), then run `/n1:n1-finish <ID>`." (with `prMode: "skip"`: "Run `/n1:n1-finish <ID>` to merge locally."). Then continue to FINALIZE MEMORY — no summary, no yield. The chain runs last, after FINALIZE MEMORY.
