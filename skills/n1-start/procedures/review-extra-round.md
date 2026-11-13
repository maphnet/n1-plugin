# Review: out-of-scope filter on incremental re-reviews (N1-345, N1-569)

Read from `steps/review.md` (`INCREMENTAL=true`: § Filter). Policy: `references/architecture.md § Review Fix Cap`. The N1-345 one-time extra round and its ledger row are retired; `procedures/review-fix-budget.md` gates every FAIL cycle.

## Filter

Runs on every incremental re-review, after the reviewers return and the **Tree freeze** passes, before `fp-new.tsv`, the verdict and review-hdr.md. First `rm -f "$N1_HOME/memory/$ID/review-index.md" "$N1_HOME/memory/$ID/review-oos.md"` so no stale file stands in. Then write every Index line from all reviewer returns (every severity and prefix, `[RULE-N]` included), verbatim, one per line, to `$N1_HOME/memory/$ID/review-index.md` with the file-write mechanism (no Index lines: write an empty file); never put a title or path in a shell command. Then:

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
