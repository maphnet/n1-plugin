#!/usr/bin/env bash
# tests/test_frontmatter.sh — NP-241: n1_write_frontmatter must not rely on a
# shimmable grep for its CR-tolerant guard (Claude Code's Bash-tool ugrep shim
# fails to parse a literal-CR pattern and would silently no-op every write).
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert_eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected=[$2] actual=[$3])"; FAIL=$((FAIL+1)); fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source "$REPO_ROOT/lib/frontmatter.sh"

# Shim reproduction: ugrep under Claude Code's Bash tool fails to parse a
# pattern containing a literal CR (splits it into an invalid alternation,
# exit 2). Model that here, scoped to this test file only (a shell function
# in a bash script only exists for that script's process).
grep() {
    case "$*" in
        *$'\r'*) echo "grep: invalid pattern" >&2; return 2 ;;
        *) command grep "$@" ;;
    esac
}

LF="$T/lf.md"
printf -- '---\na: 1\n---\n' > "$LF"
n1_write_frontmatter "$LF" a 2 >/dev/null
assert_eq "LF write succeeds under shimmed grep" "2" "$(n1_read_frontmatter "$LF" a)"

CRLF="$T/crlf.md"
printf -- '---\r\na: 1\r\n---\r\n' > "$CRLF"
n1_write_frontmatter "$CRLF" a 2 >/dev/null
assert_eq "CRLF write succeeds under shimmed grep" "2" "$(n1_read_frontmatter "$CRLF" a)"

# N1-549: NUL-filled file is refused by write and reported by read
NUL="$T/nul.md"; head -c 2022 /dev/zero > "$NUL"; cp "$NUL" "$T/nul.orig"
assert_eq "read of NUL file is empty" "" "$(n1_read_frontmatter "$NUL" a 2>/dev/null)"
assert_eq "read of NUL file prints ERROR" "ERROR: NUL bytes in $NUL" "$(n1_read_frontmatter "$NUL" a 2>&1 >/dev/null)"
n1_read_frontmatter "$NUL" a >/dev/null 2>&1; assert_eq "read of NUL file rc 0" "0" "$?"
NUL2="$T/nul2.md"; { printf -- '---\na: 1\n---\n'; head -c 8 /dev/zero; } > "$NUL2"; cp "$NUL2" "$T/nul2.orig"
n1_write_frontmatter "$NUL2" a 2 2>/dev/null; assert_eq "write with NUL after frontmatter rc 1" "1" "$?"
cmp -s "$NUL2" "$T/nul2.orig"; assert_eq "NUL-after-frontmatter file byte-identical after write" "0" "$?"
assert_eq "read of key before NULs returns value" "1" "$(n1_read_frontmatter "$NUL2" a 2>/dev/null)"
assert_eq "read of key before NULs emits no stderr" "" "$(n1_read_frontmatter "$NUL2" a 2>&1 >/dev/null)"
: > "$T/empty.md"
n1_has_nul "$T/empty.md"; assert_eq "n1_has_nul on empty file nonzero" "1" "$?"
n1_has_nul "$T/missing.md"; assert_eq "n1_has_nul on missing file nonzero" "1" "$?"
assert_eq "clean file read emits no stderr" "" "$(n1_read_frontmatter "$LF" zz 2>&1)"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
