# Review: one automatic extra fix round at the cap (N1-345)

Read from `steps/fix.md` (**Exhausted**: § Grant) and `steps/review.md` (`INCREMENTAL=true`: § Filter). Policy, reach and the `[granted]` row: `references/architecture.md § Review Fix Cap`.

## Grant

First thing in **Exhausted**, before the auto-accept branch and before the ask, headless and queue included. This check never asks.

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/fingerprints.sh"
MEM="$N1_HOME/memory/$ID"
FIX_GRANT=$(n1_review_fix_grant "$MEM/overview.md" "$MEM/fingerprints.jsonl" "$MEM/fix.diff") || true
echo "FIX_GRANT=$FIX_GRANT"
```

`FIX_GRANT=granted`: the helper wrote the one `[granted]` ledger row; never write it yourself. Skip the rest of **Exhausted**: no ask, no `[auto]` row, no For Human Review write, no Headless Guard. The **Cap gate**'s no-developer rule does not apply to this one cycle: continue `steps/fix.md` at its first block after **Exhausted** (the `pre-fix-sha` block, so `fix.diff` and `fix-changed-files` cover only this cycle) exactly as for an allowed FAIL cycle: Ensure Dependencies, rules injection, the FAIL-only `n1_increment_counter` block, the **FAIL** dispatch, the fix-changed-files/fix.diff block, return to Step 7.

Any other value (`deny:<reason>` or empty): continue **Exhausted** unchanged. The grant holds at most once per run, so a later cap-reached state always denies and reaches the ask (or the Headless Guard).

## Filter

After the reviewers return and the **Tree freeze** passes, before `fp-new.tsv`, the verdict and review-hdr.md:

```bash
source ~/.n1/preamble.sh
XR=$(n1_review_fix_extra_round "$N1_HOME/memory/$ID/overview.md"); echo "XR=$XR"
```

`XR` other than `true`: stop here; `steps/review.md` runs unchanged. `XR=true` (the one granted round): first `rm -f "$N1_HOME/memory/$ID/review-index.md" "$N1_HOME/memory/$ID/review-oos.md"` so no stale file stands in. Then write every Index line from all reviewer returns (every severity and prefix, `[RULE-N]` included), verbatim, one per line, to `$N1_HOME/memory/$ID/review-index.md` with the file-write mechanism (no Index lines: write an empty file); never put a title or path in a shell command. Then:

```bash
source ~/.n1/preamble.sh
source "$N1_ROOT/lib/fingerprints.sh"
MEM="$N1_HOME/memory/$ID"; CYCLE=$(n1_read_frontmatter "$MEM/overview.md" review_fix_cycle)
n1_fingerprint_filter_oos "$MEM/fingerprints.jsonl" "$CYCLE" "$MEM/fix-changed-files" "$MEM/review-prev.md" "$MEM/review-index.md" > "$MEM/review-oos.md"
echo "OOS=$(grep -c '^- \[' "$MEM/review-oos.md")"
```

Read `review-index.md`: its lines alone are this review's findings for `fp-new.tsv`, the summed counts, the verdict and the review-hdr.md Index. Only a finding with a new id or a new file (same id and file open in review-prev.md counts as old) in a single repo-relative path the fix did not change is removed; `[SEC-N]` lines and any finding whose title names a security class (auth, crypto, input validation, secret/token, network/HTTP, serialization, path/file handling, SQL/injection, shell/command, XSS/CSRF, race/TOCTOU, symlink, privilege, eval, sandbox, untrusted input; case-insensitive substring, any id prefix) are never filtered, so security findings always stay in the loop. The removed findings are new and sit in files the fix did not change, so they never enter `fp-new.tsv`, NON_CONVERGING or the verdict. `OOS` above 0: right after the review.md block that cats review.md, run:

```bash
source ~/.n1/preamble.sh
MEM="$N1_HOME/memory/$ID"
[ -s "$MEM/review-oos.md" ] && { printf '\n## For Human Review\n\n'; cat "$MEM/review-oos.md"; } >> "$MEM/review.md"
```

Later writes to `## For Human Review` (fix.md **Exhausted**) merge into this section and keep these lines.
