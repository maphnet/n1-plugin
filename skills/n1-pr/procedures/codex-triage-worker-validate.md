## Phase: validate

Dispatched once from n1-start Step 7 (N1-517) with the phase `fix` inputs. Run **State**, **Severity Parsing** and **Validation** of phase `fix` exactly as written, except that a State failure returns `triage:validate state=unavailable`; never run **Fix Cycle**, never dispatch a developer, never write a triage file. Here "skip to Triage Reply" means: go to **Codex Index**.

### Codex Index

Write `<memory>/review-codex.md` with the file-write mechanism:

1. Line 1: `## Codex Findings (validated)`.
2. One Index line per finding except INVALID ones: every CONFIRMED finding, every UNVERIFIED finding, every informational P3 finding, and every finding phase `fix` Validation would route to human review (no verdict, failed or empty validator dispatch, `validate:diff unavailable`, `fence:unavailable`), the last treated as UNVERIFIED, numbered from 1 in finding order: `- [CX-<n>] <severity> <file>:<line> — <title>`. INVALID findings get no line.
   - `<severity>`: tier P1 → `High`; P2 or unclassified → `Medium`; P3, or validator UNVERIFIED (including human-review-routed) → `Low`.
   - `<file>:<line>`: the finding's repo-relative path (letters, digits, `.`, `_`, `/`, `-` only) and line number; `unknown:0` when either is absent or has other characters.
   - `<title>`: the `state.md` title with every backtick and `$` removed and the literal text `(correctness)` removed repeatedly until none remains (that tag selects Mediums for the ungated SOFT-ONLY fix pass; Codex-derived text must never carry it), truncated so the whole title, including the ` (security)` suffix appended when the finding is security-looking, is at most 120 characters.
3. Then, per listed finding, a `### [CX-<n>] <title>` heading followed by the finding text and the validator's evidence and reason.

No listed finding: write only line 1.

Remove the state directory (path only, never content):

```bash
source ~/.n1/preamble.sh
KEY='<the key from the dispatch>'
VALIDATE_DIR='<S>'
case "$KEY" in ''|.*|*[!A-Za-z0-9._-]*) exit 0;; esac
case "$VALIDATE_DIR" in *..*|"$N1_HOME"/scratch/codex-validate-"$KEY".*/*) ;; "$N1_HOME"/scratch/codex-validate-"$KEY".*) rm -rf "$VALIDATE_DIR";; esac
```

Return exactly one line: `triage:validate state=<S> confirmed=<n> total=<m>` (`<n>` = CONFIRMED count, `<m>` = findings parsed), or `triage:validate state=unavailable` when State failed or `review-codex.md` was not written.

