#!/usr/bin/env bash
# lib/stall.sh — same-failure stall stop for the QA, local-testing and CI fix loops (N1-346).
# A signature is the sha256 of the sorted, unique, non-blank failure names (names only: details,
# links and timings are excluded). An empty signature never matches. Rules: skills/n1-start/procedures/stall-stop.md.
_N1_STALL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_N1_STALL_LIB/frontmatter.sh"
source "$_N1_STALL_LIB/treestate.sh"

# n1_stall_sig: names on stdin -> hex hash; nothing when there is no non-blank line.
n1_stall_sig() {
    local names
    names=$(awk 'NF' | LC_ALL=C sort -u)
    [ -n "$names" ] || return 0
    printf '%s\n' "$names" | _n1_sha256
}

# n1_stall_names_lt <local-testing.md>: Scenario of each Ad-Hoc row whose Result is exactly FAIL,
# then class:<Failure class> when at least one FAIL row printed. Failures only in existing e2e print nothing.
n1_stall_names_lt() {
    [ -f "$1" ] || return 0
    awk '
        /^### / { in_t = ($0 ~ /^### Ad-Hoc Scenario Results/); next }
        /Failure class:/ && cls == "" { c = $0; sub(/.*Failure class:[*[:space:]]*/, "", c); sub(/[[:space:]]+$/, "", c); cls = c }
        in_t && /^\|/ {
            row = $0; gsub(/\\[|]/, "\001", row)   # an escaped pipe is cell text, not a delimiter
            if (split(row, f, "|") < 5) next
            r = f[4]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", r)
            s = f[3]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            gsub(/\001/, "|", s)
            if (r == "FAIL" && s != "") { print s; hit = 1 }
        }
        END { if (hit && cls != "") print "class:" cls }
    ' "$1"
}

# n1_stall_names_ci <fail-lines-file>: check name (field 2) of each poll FAIL<TAB>name<TAB>link line.
n1_stall_names_ci() {
    [ -f "$1" ] || return 0
    awk -F'\t' '$1 == "FAIL" && $2 != "" { print $2 }' "$1"
}

# n1_stall_check <overview.md> <key> <sig>: stores <sig> (empty included; non-hex is blanked).
# Prints stalled (rc 0) only when <sig> is non-empty and equals the stored value; else ok (rc 1).
# A missing overview.md (standalone n1-ci) always gives ok.
n1_stall_check() {
    local o="$1" k="$2" sig="$3" prev
    case "$sig" in *[!0-9a-f]*) sig="" ;; esac
    prev=$(n1_read_frontmatter "$o" "$k")
    n1_write_frontmatter "$o" "$k" "$sig" || { echo ok; return 1; }
    if [ -n "$sig" ] && [ "$sig" = "$prev" ]; then echo stalled; return 0; fi
    echo ok; return 1
}

# n1_stall_reset <overview.md> <key>...: writes each key empty (user-continue paths). Never fails.
n1_stall_reset() {
    local o="$1" k; shift
    for k in "$@"; do n1_write_frontmatter "$o" "$k" "" || true; done
    return 0
}
