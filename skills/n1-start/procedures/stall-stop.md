# Same-failure stall stop (N1-346)

Read from `steps/qa.md` (**FAIL**: § QA), `procedures/local-testing-run.md` (9d entry: § Local testing) and n1-ci `steps/02-fix.md` (Step 5 entry: § CI). User-continue paths run § Reset. Policy: `references/architecture.md § Same-Failure Stall Stop`.

A loop stalls when two consecutive failing rounds have the same non-empty signature (sha256 of the sorted failure names; details, links and timings are excluded). `n1_stall_check` always stores the new signature; an empty signature never matches. A stalled round runs no cap test, no counter increment and no developer. Caps and defaults do not change.

## QA

At the **FAIL** branch of `steps/qa.md`, before the cap test:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/testparse.sh"; source "$N1_ROOT/lib/stall.sh"; QD="$N1_HOME/memory/$ID"
SIG=$(n1_testparse_failed_names "$QD/qa-verify.log" | n1_stall_sig)
echo "STALL=$(n1_stall_check "$QD/overview.md" qa_fail_sig "$SIG") FAILED_TESTS=$(n1_testparse_failed_names "$QD/qa-verify.log" | grep -c .)"
```

`STALL=ok`: continue the **FAIL** branch (cap test, increment, developer).

`STALL=stalled`: no increment, no developer. Run § Autonomy Gate (`procedures/autonomy-headless.md`) with step=`qa`, action=`accept the QA failure and proceed to review`, ledger_context=`QA stalled on the same failure: <FAILED_TESTS> failing tests, see qa-verify.log`. Under `qualityEscalations=auto-accept`: take the action, add the key decision `QA: stalled on the same failure`, run the final block of `steps/qa.md` once with `failed`, continue to the review step. Otherwise prompt "QA stalled on the same failure: the same tests failed in two consecutive rounds (see `qa-verify.log`). Options:"
No recommendation. The options are equivalent given the available evidence; select based on team preference.
1 — Proceed to review with the failure recorded: key decision `QA: stalled on the same failure`, final block with `failed`, continue to review
2 — One more fix cycle: run § Reset with `qa_fail_sig`, then continue the **FAIL** branch (cap test, increment, developer)
3 — Abort: final block with `failed`, stop

**Headless:** under `N1_HEADLESS=1` apply `procedures/autonomy-headless.md § Headless Guard`. This prompt has no recommended option (it states "No recommendation", per `defaults/rules/recommended-option.rule.md`) and option 1 is not a default, so the guard escalates, as at the cap.

## Local testing

At the 9d entry of `procedures/local-testing-run.md`, before the developer spawn:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/stall.sh"; M="$N1_HOME/memory/$ID"
SIG=$(n1_stall_names_lt "$M/local-testing.md" | n1_stall_sig)
echo "STALL=$(n1_stall_check "$M/overview.md" local_test_fail_sig "$SIG")"
```

`STALL=ok`: continue 9d unchanged.

`STALL=stalled`: no developer spawn, no increment, no re-run. Go to the 9d cap exit: its Autonomy gate with step=`local-testing`, action=`skip local testing and proceed to PR`, ledger_context=`<scenarios that still fail>; stalled on the same failure after <N> fix cycles` (N = `local_test_fix_cycle`), with the cap's key decision and skipped `n1_step_end`. Otherwise its options prompt, prefixed with "Stalled on the same failure. ". Options 1 and 3 run § Reset with `local_test_fail_sig`. **Headless:** as at the cap.

## CI

N1 runs only: skip this section when `$N1_HOME/memory/$ID/overview.md` does not exist (standalone n1-ci has no stall detection).

At Step 5 entry, before classification: write the `FAIL` lines of the latest poll verbatim (`FAIL<TAB>name<TAB>link`, cancelled checks included) to `$N1_HOME/memory/$ID/ci-fail.tsv` with the file-write mechanism. Never put a check name in a shell command, variable or double-quoted string. Then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/stall.sh"; M="$N1_HOME/memory/$ID"
SIG=$(n1_stall_names_ci "$M/ci-fail.tsv" | n1_stall_sig); rm -f "$M/ci-fail.tsv"
echo "STALL=$(n1_stall_check "$M/overview.md" ci_fail_sig "$SIG")"
```

`STALL=ok`: continue Step 5.

`STALL=stalled`: no classification, no developer, no increment. Go to **Step 6b** and present "CI stalled on the same failure: <failed check names>" with the remaining failures and fix history. The Step 6b menu is unchanged and nothing auto-accepts under any `qualityEscalations` value (D1). Headless runs escalate as at the cap.

NOT_BRANCH_CAUSED (Step 6, "After developer returns" item 2): run § Reset with `ci_fail_sig`. Step 5 already stored this round's signature, so clearing it keeps the round from counting toward a stall (D8).

## Reset

Every user-continue path clears its loop's signature, so the next failing round stores a fresh one and cannot stall at once: QA option 2 (`qa_fail_sig`); local-testing 9d options 1 and 3 (`local_test_fail_sig`); n1-ci Step 5 `escalate` classification and Step 5b option 2, Step 6b options 1 and 3, the NOT_BRANCH_CAUSED branch and the n1-ci Step 7 run end (`ci_fail_sig`, N1 runs only; the run-end clear stops a later n1-ci run on the same PR from stalling on a previous run's failure). Ticket-watch re-plans clear all three keys in `n1_tw_replan_reset`.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/stall.sh"
n1_stall_reset "$N1_HOME/memory/$ID/overview.md" <key>
```
