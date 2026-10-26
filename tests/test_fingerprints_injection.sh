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
eq "record exits 0" "0" "$?"
eq "\$(...) in title not executed" "absent" "$([ -e "$T/S1" ] && echo present || echo absent)"
eq "backticks in title not executed" "absent" "$([ -e "$T/S2" ] && echo present || echo absent)"
eq "one JSONL row per valid TSV line" "3" "$(wc -l < "$T/fingerprints.jsonl" | tr -d ' ')"
eq "hostile title fp matches direct finding" "$(n1_fingerprint_finding 'lib/a.sh' "$EVIL")" "$(fp_of "$T/fingerprints.jsonl" CR-1)"
eq "CRLF + tab title fp matches direct finding" "$(n1_fingerprint_finding './Lib/B.sh' "$TABBED")" "$(fp_of "$T/fingerprints.jsonl" SEC-2)"
eq "last line without newline recorded" "$(n1_fingerprint_finding 'c.sh' 'no trailing newline')" "$(fp_of "$T/fingerprints.jsonl" CR-3)"
eq "severity recorded" "1" "$(grep -c '"id":"SEC-2","severity":"Critical","status":"active","cycle":2' "$T/fingerprints.jsonl")"
eq "malformed line skipped" "0" "$(grep -c '"id":"CR-9"' "$T/fingerprints.jsonl")"
eq "malformed line warned" "1" "$(grep -c 'CR-9' "$T/err")"

n1_fingerprint_record "$T/fingerprints.jsonl" "$T/missing.tsv" 1 2>/dev/null
eq "missing TSV fails closed" "1" "$?"
eq "TSV consumed after recording" "absent" "$([ -e "$T/fp-new.tsv" ] && echo present || echo absent)"

exit $FAIL
