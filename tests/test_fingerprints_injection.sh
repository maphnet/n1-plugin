#!/usr/bin/env bash
# N1-136: reviewer finding titles reach review fingerprints as file data, never as shell command text.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
source lib/fingerprints.sh

eq() { # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=1; fi
}
fp_of() { # <jsonl> <id> -> fp recorded for that id
    grep "\"id\":\"$2\"" "$1" | sed 's/.*"fp":"\([^"]*\)".*/\1/'
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Normalization pin: strip ./, lowercase, collapse whitespace, trim (guards ledger hash parity).
eq "finding hash normalization unchanged" "$(_n1_portable_hash 'foo.sh:a b')" "$(n1_fingerprint_finding './Foo.sh' '  A  B ')"

# Hostile title: command substitution, backticks, double and single quotes.
EVIL='x $(touch S1) `touch S2` "q'"'"' end'
TABBED=$'Tab\tin title'
{
    printf '%s\t%s\t%s\t%s\n' 'CR-1' 'High' 'lib/a.sh' "$EVIL"
    printf '\n'
    printf '%s\t%s\t%s\t%s\r\n' 'SEC-2' 'Critical' './Lib/B.sh' "$TABBED"
    printf '%s\t%s\t%s\n' 'CR-9' 'High' 'only-three-fields'
    printf '%s\t%s\t%s\t%s' 'CR-3' 'High' 'c.sh' 'no trailing newline'
} > "$T/fp-new.tsv"

( cd "$T" && n1_fingerprint_record "$T/fingerprints.jsonl" "$T/fp-new.tsv" 2 2>"$T/err" )
eq "record exits non-zero when a row is malformed" "1" "$?"
eq "\$(...) in title not executed" "absent" "$([ -e "$T/S1" ] && echo present || echo absent)"
eq "backticks in title not executed" "absent" "$([ -e "$T/S2" ] && echo present || echo absent)"
eq "one JSONL row per valid TSV line" "3" "$(wc -l < "$T/fingerprints.jsonl" | tr -d ' ')"
eq "hostile title fp matches direct finding" "$(n1_fingerprint_finding 'lib/a.sh' "$EVIL")" "$(fp_of "$T/fingerprints.jsonl" CR-1)"
eq "CRLF + tab title fp matches direct finding" "$(n1_fingerprint_finding './Lib/B.sh' "$TABBED")" "$(fp_of "$T/fingerprints.jsonl" SEC-2)"
eq "last line without newline recorded" "$(n1_fingerprint_finding 'c.sh' 'no trailing newline')" "$(fp_of "$T/fingerprints.jsonl" CR-3)"
eq "severity recorded" "1" "$(grep -c '"id":"SEC-2","severity":"Critical","status":"active","cycle":2' "$T/fingerprints.jsonl")"
eq "malformed line skipped" "0" "$(grep -c '"id":"CR-9"' "$T/fingerprints.jsonl")"
eq "malformed line warned" "1" "$(grep -c 'malformed' "$T/err")"

n1_fingerprint_record "$T/fingerprints.jsonl" "$T/missing.tsv" 1 2>/dev/null
eq "missing TSV fails closed" "1" "$?"
eq "TSV kept when a row was skipped as .rejected" "present:absent" "$([ -e "$T/fp-new.tsv.rejected" ] && echo present || echo absent):$([ -e "$T/fp-new.tsv" ] && echo present || echo absent)"
printf 'CR-4\tHigh\td.sh\tok\n' > "$T/ok.tsv"
n1_fingerprint_record "$T/ok.jsonl" "$T/ok.tsv" 1
eq "clean record exits 0" "0" "$?"
eq "TSV consumed after full success" "absent" "$([ -e "$T/ok.tsv" ] && echo present || echo absent)"

# Empty file field kept; invalid id/severity skipped with non-zero; unwritable JSONL keeps TSV.
{
    printf '%s\t%s\t%s\t%s\n' 'CR-5' 'High' '' 'No Path Title'
    printf '%s\t%s\t%s\t%s\n' 'CR-6"x' 'High' 'a.sh' 'bad id'
    printf '%s\t%s\t%s\t%s\n' 'CR-7' 'Bogus' 'a.sh' 'bad sev'
} > "$T/fp2.tsv"
n1_fingerprint_record "$T/fp2.jsonl" "$T/fp2.tsv" 1 2>/dev/null
eq "invalid rows make record return non-zero" "1" "$?"
eq "empty file field kept with correct title hash" "$(n1_fingerprint_finding '' 'No Path Title')" "$(fp_of "$T/fp2.jsonl" CR-5)"
eq "invalid id/severity skipped" "1" "$(wc -l < "$T/fp2.jsonl" | tr -d ' ')"
eq "TSV kept after skipped rows as .rejected" "present:absent" "$([ -e "$T/fp2.tsv.rejected" ] && echo present || echo absent):$([ -e "$T/fp2.tsv" ] && echo present || echo absent)"
printf 'CR-8\tHigh\ta.sh\tt\n' > "$T/fp3.tsv"
mkdir -p "$T/ro" && : > "$T/ro/x"
n1_fingerprint_record "$T/ro/x/f.jsonl" "$T/fp3.tsv" 1 2>/dev/null
eq "unwritable JSONL returns non-zero" "1" "$?"
eq "TSV kept after append failure as .rejected" "present:absent" "$([ -e "$T/fp3.tsv.rejected" ] && echo present || echo absent):$([ -e "$T/fp3.tsv" ] && echo present || echo absent)"

# Wiring: both call sites write findings by file and record via the helper.
R=skills/n1-start/steps/review.md
A=skills/n1-review/steps/01-analyze.md
for S in "$R" "$A"; do
    eq "$S has no double-quoted <file>/<title> placeholders" "0" "$(grep -cE '"<(file|title)>"' "$S")"
    eq "$S records via n1_fingerprint_record" "1" "$(grep -cE 'n1_fingerprint_record "\$FP_FILE" ' "$S")"
    eq "$S names the memory-path fp-new.tsv" "1" "$(grep -c 'fp-new\.tsv` with' "$S")"
    eq "$S writes fp-new.tsv with the file-write mechanism" "1" "$(grep -cE 'fp-new\.tsv` with the file-write mechanism' "$S")"
    eq "$S forbids titles in shell strings" "1" "$(grep -ciE 'never put a title or path in a shell command, variable or double-quoted string' "$S")"
    eq "$S no longer calls n1_fingerprint_finding inline" "0" "$(grep -c 'n1_fingerprint_finding' "$S")"
done

exit $FAIL
