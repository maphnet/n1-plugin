#!/usr/bin/env bash
# N1-589: split prompt files. Every part exists and opens with a heading, every part is
# named by a pointer that states its condition on the same line, personas that follow
# pointers resolve the plugin root, and no `<file> § <Section>` cite lands on a part of a
# split group that does not hold the section.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
source tests/persona_split_lib.sh
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
PTRS=$(printf '%s\n' "${PS_POINTERS[@]}")

# 1. every part exists, opens with a heading and is named by at least one pointer
for g in "${PS_GROUPS[@]}"; do
    declare -n arr="PS_$g"
    [ -f "${arr[0]}" ] && ok "$g: entry ${arr[0]} exists" || no "$g: entry ${arr[0]} missing"
    for f in "${arr[@]:1}"; do
        first=$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)
        case "$first" in '#'*) ok "$g: $f opens with a heading" ;; *) no "$g: $f missing or not opening with a heading" ;; esac
        if grep -qF -- "|$(basename "$f")|" <<<"$PTRS"; then ok "$g: $f has a pointer"; else no "$g: $f has no pointer row"; fi
    done
    unset -n arr
done

# 2. pointers: the holding file has one line naming both the part and the condition
for row in "${PS_POINTERS[@]}"; do
    IFS='|' read -r from part cond <<<"$row"
    n=$(grep -F -- "$part" "$from" 2>/dev/null | grep -cF -- "$cond")
    if [ "${n:-0}" -ge 1 ]; then ok "pointer $from -> $part ($cond)"; else no "pointer $from -> $part ($cond) missing"; fi
done

# 3. personas resolve the plugin root once before following a pointer
for f in "${PS_ROOTLINE[@]}"; do
    n=$(grep -cF 'source ~/.n1/preamble.sh && printf %s "$N1_ROOT"' "$f")
    if [ "$n" = 1 ]; then ok "$f resolves the plugin root"; else no "$f plugin-root line count $n (want 1)"; fi
done

# 4. `<file> § <Section>` cites land on the part that holds the section
names() { # headings and leading bold labels of $1, without '#', '§ ', a trailing ':' or ' (...)'
    sed -nE -e 's/^#+[[:space:]]+(§[[:space:]]+)?//p' -e 's/^\*\*([^*]+)\*\*.*/\1/p' "$1" \
        | sed -E -e 's/:$//' -e 's/[[:space:]]+\([^)]*\)$//' -e 's/[[:space:]]+$//'
}
CITE_FAIL=0
for g in "${PS_GROUPS[@]}"; do
    declare -n arr="PS_$g"
    for f in "${arr[@]}"; do
        b=$(basename "$f")
        while IFS= read -r cite; do
            rest=${cite#*§ }; rest=${rest%"${rest##*[![:space:]]}"}
            self=no; other=""
            for p in "${arr[@]}"; do
                while IFS= read -r nm; do
                    [ -n "$nm" ] || continue
                    case "$rest" in "$nm"*) ;; *) case "$nm" in "$rest"*) ;; *) continue ;; esac ;; esac
                    if [ "$p" = "$f" ]; then self=yes; else other=$p; fi
                done < <(names "$p")
            done
            if [ "$self" = no ] && [ -n "$other" ]; then no "cite '$b § $rest' should point at $other"; CITE_FAIL=1; fi
        done < <(grep -rhoE -- "${b//./\\.}\`? § [^\`.;,()]+" skills references agents lib hooks 2>/dev/null)
    done
    unset -n arr
done
[ $CITE_FAIL -eq 0 ] && ok "split-group cites resolve to the part holding the section"
exit $FAIL
