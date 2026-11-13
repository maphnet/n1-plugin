# Review: progress-gated fix budget (N1-569)

Read from `steps/fix.md` (**Cap gate**, the FAIL contract fence, **Exhausted**) and `procedures/review-incremental.md`. Policy summary: `references/architecture.md § Review Fix Cap`.

## Gate

`n1_review_fix_gate` (lib/config.sh) decides every FAIL cycle; never override it. Budget: `review.maxFixAttempts` FAIL fix cycles (default 3; a configured value is the upper bound). Cycle 1 always runs. Cycle N+1 runs only when the re-review after cycle N resolved at least one blocking finding (a `resolved`, `withdrawn`, `downgraded` or `oos` row in bucket N of `fingerprints.jsonl`), no blocking finding is `carried` with age 2 or more (open after two fix cycles), and the developer met § Contract. The rule is the same in interactive, headless and queue runs: an allowed cycle never asks. Each gate call appends `{"cycle":N,"decision":"allow|deny","reason":"..."}` to `memory/<ID>/fix-gate.jsonl`. Reasons: `first`, `progress`, `cap`, `no-progress`, `carried`, `contract`, `no-data` (no state rows: unknown progress never buys a cycle), `counter`. The fix step's last block passes `n1_review_fix_outcome` (gate log plus per-round finding states) to `n1_step_end`; never write either file yourself.

**Blocking set** (`n1_review_blocking_ids`, lib/fingerprints.sh; equal to the FAIL dispatch scope): Critical/High; every `[RULE-N]`; every non-TQ Medium except ` (pre-existing)`; every non-Low `[SEC-N]` (and `[CX-N]` titled ` (security)`) except ` (pre-existing)`.

## Contract

The FAIL developer writes, in its `## Fix Cycle <N>` section of implementation.md, one line per blocking ID:

- `- [ID] fixed: <what changed>`
- `- [ID] disputed: <why the finding is wrong, not a defect, or outside this ticket>`
- `- [ID] needs-decision: <the question a human must answer>`

A blocking finding is never listed under `Findings deferred`. After the FAIL developer returns, run the contract fence in `steps/fix.md`. `FIX_CONTRACT=missing: <IDs>`: dispatch the developer once more in this cycle (no counter increment, same model, rules block and output path) with "Add one contract line per listed ID to `## Fix Cycle <N>`; fix what you can." and the missing IDs. Then run the fence again with the line `FIX_FINAL=final` added right after its `source` line (the helper then logs the miss). A second miss is logged to `fix-gate.jsonl` and the next gate denies `contract`: the cycle counts as no progress. Never write contract lines yourself. `missing: review.md` and `missing: bad cycle` are not finding IDs: never dispatch them; STOP and escalate (review.md or the `review_fix_cycle` counter is unreadable).

## Disputes

The persona that raised a `disputed` finding rules on it inside the next incremental re-review: `[SEC-N]` → security-reviewer; `[CX-N]` titled ` (security)` → security-reviewer when spawned, else code-reviewer; `[CR-N]`, `[RULE-N]`, `[XREPO-N]` and other `[CX-N]` → code-reviewer (Codex runs at cycle 0 only). The reviewer gets the implementation.md path and the `## Fix Cycle <N>` heading and returns one status line per ruling: stands → `OPEN`, withdrawn → `WITHDRAWN`, downgraded to non-blocking → `DOWNGRADED` (its Index line, if any, is Low), out of scope → `OOS`. Withdrawn, downgraded and out-of-scope findings leave the blocking Index, so they do not fail the re-review; stands keeps the finding in the Index and blocking. For each `OOS` line: file a follow-up per `<N1_ROOT>/references/followup-filing.md` § Append (source `review`) and add the finding to `## For Human Review` in review.md (file-write; merge if present).

## Needs decision

A `needs-decision` line whose question falls in a stop-list category (`procedures/autonomy-headless.md § Headless Guard`: security, architecture, public API) is asked in this cycle, not at the budget end: ask the user the developer's question (format: `<N1_ROOT>/references/question-format.md`), add an `[asked]` ledger row in step `fix`, then dispatch the developer once more in this cycle (no counter increment) with the answer for those IDs. Headless: § Headless Guard (stop list: pause or escalate). Any other category: add an `[auto]` ledger row naming the ID, no ask and no re-dispatch; the finding stays open and § Gate decides the next cycle.

## Status lines

Every incremental re-review returns, besides its Index, one line per prior blocking ID from review-prev.md that the reviewer owns (ownership as in § Disputes):

`- [ID] FIXED | OPEN | OPEN as [NEW-ID] | WITHDRAWN | DOWNGRADED | OOS`

`OPEN as [NEW-ID]` names the new Index ID of the same defect after a re-number or re-title. Write all returned status lines verbatim to `memory/<ID>/review-status.md` (file-write, never a shell command) before the review collect block. `n1_review_collect` derives the states with `n1_fix_states` and prints `FIX_STATES:`. A prior ID with no line is carried when the new Index has the same ID in the same file or the same fingerprint, else resolved, and is counted as `unlabeled`. `FIXED` for an ID the new Index still lists in the same file counts as carried. `NON_CONVERGING` prints only when nothing was resolved and something was carried; it routes to Step 8, where the gate stops the loop.

## Exit

When `FIX_GATE` is not `allow` and FAIL findings are open (`steps/fix.md` **Exhausted**):

- Headless (`N1_HEADLESS=1`, queue children included): always the For Human Review exit, open in-diff non-Low `[SEC-N]` included and listed first, with no ask, no Headless Guard and no pause: the `[auto]` ledger row, `## Review` `FAIL (unresolved, human review)`, the PR opens. A FAIL verdict is never merged: the review pin (lib/config.sh) refuses a review.md that does not open `### Verdict: PASS`, so finish and the queue chain stop before merge.
- Interactive: with no open in-diff non-Low `[SEC-N]` or security-class finding, the same For Human Review exit with no ask; otherwise the ask in `steps/fix.md` **Exhausted**. An answered option 2 adds the `[asked]` row and runs one cycle; `n1_review_fix_audit` counts that row once the counter passes the budget. A deny before the budget is spent (`no-progress`, `carried`, `contract`, `no-data`) takes the same exit.
