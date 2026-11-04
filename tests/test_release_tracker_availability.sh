#!/usr/bin/env bash
# N1-245: n1-release takes only the leading [PREFIX-N] tag in ticket discovery Sources C/D,
# and reports tracker ticket operations as SKIPPED when the tracker.mcp server is not loaded.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R01=skills/n1-release/steps/01-resolve-metadata.md
R03=skills/n1-release/steps/03-tracker-release.md
R03B=skills/n1-release/steps/03b-release-notes.md
R04=skills/n1-release/steps/04-report.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; FAIL=1; fi
}

# --- Sources C/D: evaluate the snippet lines from 01 against fixtures (AC4, AC5)
GIT_LINE=$(sed -n 's/^ *\(GIT_IDS=.*\)$/\1/p' "$R01")
GH_LINE=$(sed -n 's/^ *\(GH_IDS=.*\)$/\1/p' "$R01")
expect "01 has exactly one GIT_IDS line" "1" "$(grep -c . <<<"$GIT_LINE")"
expect "01 has exactly one GH_IDS line" "1" "$(grep -c . <<<"$GH_LINE")"
git_ids() { local GIT_LOG="$1" PREFIX=VEL GIT_IDS=""; eval "$GIT_LINE"; printf '%s' "$GIT_IDS"; }
gh_ids() { local GH_BODY="$1" PREFIX=VEL GH_IDS=""; eval "$GH_LINE"; printf '%s' "$GH_IDS"; }

SUBJ='[VEL-2976] Accept several API keys; drop committed key from VEL-1188 plan (#36)'
expect "D: leading tag only, later mention ignored" "VEL-2976" "$(git_ids "abc1234 $SUBJ")"
expect "D: untagged conventional subject yields nothing" "" "$(git_ids 'abc1234 fix: handle VEL-1188 case')"
expect "D: merge subject yields nothing" "" "$(git_ids 'def5678 Merge pull request #36 from org/VEL-1188-keys')"
expect "D: several commits, tagged ones only" "VEL-2976
VEL-3001" "$(git_ids "abc1234 $SUBJ
def5678 [VEL-3001] Other change (#37)
0a1b2c3 chore: bump VEL-9999")"
expect "C: release-note entry leading tag only" "VEL-2976" "$(gh_ids "## What's Changed
* $SUBJ by @u in https://github.com/o/r/pull/36")"
expect "C: entry with no leading tag yields nothing" "" "$(gh_ids '* fix: handle VEL-1188 case by @u in https://github.com/o/r/pull/37')"
expect "C: stakeholder prose mentioning an ID yields nothing" "" "$(gh_ids 'We fixed key handling (VEL-1188).')"
lacks "01 Sources C/D no longer grep whole lines for PREFIX" 'grep -oE "\$\{PREFIX\}' "$R01"
check "01 states the leading-tag rule" 'Only the leading `\[PREFIX-N\]` tag counts' "$R01"

exit "$FAIL"
