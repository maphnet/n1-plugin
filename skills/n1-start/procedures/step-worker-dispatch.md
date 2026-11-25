# Step Worker Dispatch (ci, local-testing)

The step's begin fence printed a `model: memory: n1_root: worktree:` line: dispatch the worker below. The orchestrator keeps the step markers, every user question, the Headless Guard, `## Pending`, the run pointer and every merge or release decision; the worker runs the step text in a fresh context and leaves `<memory>/<s>-result.md` (`<s>` is `ci` or `lt`).

## Dispatch

Dispatch persona `ci-worker` (ci step) or `local-testing-worker` (local-testing step) with the printed `model:` and only this prompt, then wait for it, foreground, per the BLOCKING DISPATCH REQUIREMENT in `<N1_ROOT>/skills/n1-start/SKILL.md` and the Wait Contract (`procedures/output-gates.md`). Keep the worker's id for § Question.

```
id: <ID>
memory: <printed memory:>
n1_root: <printed n1_root:>
worktree: <printed worktree:>
```

## ci

Result fence for the ci step:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/worker-step.sh"
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
RES=$(n1_sw_result ci); echo "$RES"
SW=$(sed -n 's/^sw://p' <<<"$RES"); O=$(sed -n 's/^outcome://p' <<<"$RES"); M=$(sed -n 's/^metadata://p' <<<"$RES")
case "$SW" in
  complete) n1_step_end "ci" 13 "$O" ${M:+"$M"};;
  stopped) n1_step_end "ci" 13 failed;;
  question) n1_sw_question ci;;
esac
```

- `sw:complete` → the step is ended. `outcome:failed` means CI is still red: note it for FINALIZE. Continue per ci.md.
- `sw:stopped` → print `n1-ci stopped: <reason:>`; the step is ended `failed`; note it for FINALIZE and continue per ci.md.
- `sw:question` → § Question.
- `sw:prompt` or `sw:unknown` → § Inline fallback.

## local-testing

Result fence for the local-testing step:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/worker-step.sh"
ID="<ID>"; case "$ID" in ""|*[!A-Za-z0-9_-]*) echo id:invalid; exit 1;; esac
RES=$(n1_sw_result lt); echo "$RES"
SW=$(sed -n 's/^sw://p' <<<"$RES"); O=$(sed -n 's/^outcome://p' <<<"$RES"); M=$(sed -n 's/^metadata://p' <<<"$RES")
case "$SW" in
  complete) n1_step_end "local-testing" 11 "$O" ${M:+"$M"};;
  stopped) n1_step_end "local-testing" 11 failed;;
  question) n1_sw_question lt;;
esac
```

- `sw:complete` → the step is ended; continue to Step 10 (PR CREATION).
- `sw:stopped` → print `local testing stopped: <reason:>`; the step is ended `failed`; stop, as after the inline Abort.
- `sw:question` → § Question.
- `sw:prompt` or `sw:unknown` → § Inline fallback.

## Question

`n1_sw_question` printed `class:`, `stop_list:`, `recommended:`, `question:` and the `option:` lines. Set `STEP` to `ci` or `local-testing`.

1. `class:lt-fix-exhausted` → first apply `procedures/autonomy-headless.md § Autonomy Gate` with step=`local-testing`, action=`skip local testing and proceed to PR`, ledger_context=the `question:` text. `stop_list:none` → the gate takes the action: resume with `answer: 2 auto-accept` (step 4). Otherwise continue with 2 or 3.
2. Attended (`N1_HEADLESS` unset) → ask the user (format: `<N1_ROOT>/references/question-format.md`) with the `question:` text and the options in order, numbered from 1. Put `(Recommended)` only on the option `recommended:` names; with `recommended:none`, no label. When the chosen option waits for the user to act (it says type 'continue'), wait until the user says continue.
3. Headless (`N1_HEADLESS=1`) → apply `procedures/autonomy-headless.md § Headless Guard` in the orchestrator, with the prompt classified by `stop_list:`. `stop_list:` other than `none`, or `recommended:none` → escalate exactly as the guard says (pause or exit); do not resume the worker. Otherwise take the recommended option and write the guard's `[auto]` ledger row.
4. Resume the worker by its id via the host message mechanism with one line, `answer: <n> <text>` (`<text>`: the user's words, `auto-accept`, or `-`). Wait per the Wait Contract, then run this step's Result fence again.

After the third round trip in one step, or when the resume fails (no id, error, no reply), go to § Inline fallback.

## Inline fallback

Note `<s>-worker returned no status; ran <step> inline` (or `stopped at a prompt` for `sw:prompt`), then:

- ci: invoke skill `n1:n1-ci` inline with the PR number, and finish ci.md exactly as after an inline n1-ci (its end block). The fix-loop state lives in overview.md frontmatter (`ci_fix_cycle`, `ci_fail_sig`, `ci_rerun_*`), so the loop continues rather than restarts.
- local-testing: run local-testing.md's **QA runner commands** block and **Ensure dependencies**, then read `procedures/local-testing-run.md` and follow it through 9a-9d without Worker mode; it ends the step.
