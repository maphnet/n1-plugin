# Story child (n1-pr)

Read from `steps/01-prepare.md` only when prepare printed `STORY` other than `none`; it is not read at entry.

`DEFAULT_BRANCH` is the story branch (`story/<STORY_ID>`) for every later step: use `origin/${DEFAULT_BRANCH}` in the Step 1 git commands (it has no local ref); the rebase and the PR target it, never the default branch. In `steps/02-push-create.md` every snippet re-derives `DEFAULT_BRANCH` from the validated story base, which overrides the transcribed value.
