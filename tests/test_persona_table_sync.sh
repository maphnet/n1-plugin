#!/usr/bin/env bash
# tests/test_persona_table_sync.sh -- N1-632: the persona tables in README.md and references/architecture.md
# must list exactly the agents/*.md personas, with model and effort equal to the agent frontmatter.
# Run: bash tests/test_persona_table_sync.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASS=0; FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
no() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Prints the frontmatter value of key $1 in file $2; CRLF-tolerant, stops at the closing ---.
fm() {
    awk -v k="$1" '{sub(/\r$/, "")} /^---$/{n++; next} n>=2{exit}
        n==1 && index($0, k ":")==1 {sub(/^[^:]*:[ \t]*/, ""); print; exit}' "$2"
}

# Prints "name model effort" per row of the table whose header is `Agent | Default Model | Effort`.
# Prints nothing when the header is absent.
rows() {
    awk '{sub(/\r$/, "")}
        !t && /^\| *Agent *\| *Default Model *\| *Effort *\|/{t=1; next}
        t && !/^\|/{exit}
        t && /^\|[ -]*\|[ -]*\|/{next}
        t{split($0, c, "|"); for (i=2; i<=4; i++) gsub(/^[ \t]+|[ \t]+$/, "", c[i]); print c[2], c[3], c[4]}' "$1"
}

# check_table <label> <doc>: prints one FAIL line per problem, returns 1 if any.
check_table() {
    local label="$1" doc="$2" r name model effort bad=0 seen=" " f
    r=$(rows "$doc")
    if [ -z "$r" ]; then echo "$label: table header not found or empty"; return 1; fi
    while read -r name model effort; do
        f="agents/$name.md"
        if [ ! -f "$f" ]; then echo "$label: row '$name' is not an agent file"; bad=1; continue; fi
        if [[ "$seen" == *" $name "* ]]; then echo "$label: duplicate row '$name'"; bad=1; fi
        seen="$seen$name "
        [ "$model" = "$(fm model "$f")" ] || { echo "$label: $name model '$model' != frontmatter '$(fm model "$f")'"; bad=1; }
        [ "$effort" = "$(fm effort "$f")" ] || { echo "$label: $name effort '$effort' != frontmatter '$(fm effort "$f")'"; bad=1; }
    done <<< "$r"
    for f in agents/*.md; do
        name=$(basename "$f" .md)
        [[ "$seen" == *" $name "* ]] || { echo "$label: agent '$name' has no row"; bad=1; }
    done
    return "$bad"
}

[ -n "$(ls agents/*.md 2>/dev/null)" ] && ok "agents/*.md found" || no "no agents/*.md (guard would be vacuous)"
for f in agents/*.md; do
    [ -n "$(fm model "$f")" ] && [ -n "$(fm effort "$f")" ] || no "$f lacks model: or effort: frontmatter"
done

# self-check: a wrong effort, an unknown row and a missing persona must all be reported
SELF=$(mktemp); trap 'rm -f "$SELF"' EXIT
{
    echo '| Agent | Default Model | Effort | Role |'
    echo '|-------|---------------|--------|------|'
    echo "| developer | $(fm model agents/developer.md) | bogus | x |"
    echo '| ghost | sonnet | low | x |'
} > "$SELF"
out=$(check_table self "$SELF"); rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"effort 'bogus'"* && "$out" == *"ghost"* && "$out" == *"has no row"* ]]; then
    ok "self-check: bad table fails"
else
    no "self-check: bad table not reported (rc=$rc)"
fi
printf '| x | y |\n' > "$SELF"
check_table self "$SELF" >/dev/null && no "self-check: missing header passed" || ok "self-check: missing header fails"

for doc in README.md references/architecture.md; do
    if out=$(check_table "$doc" "$doc"); then ok "$doc persona table matches agents/*.md"; else no "$doc persona table out of sync"; echo "$out"; fi
done

echo "Passed: $PASS Failed: $FAIL"
[ "$FAIL" -eq 0 ]
