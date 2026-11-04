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
# Source D must not see log decoration (log.decorate=short adds "(tag: ...)" after the hash)
expect "D: both Source D git log calls pass --no-decorate" "2" "$(grep -cE 'GIT_LOG=\$\(git log .*--no-decorate' "$R01")"
D_REPO=$(mktemp -d); trap 'rm -rf "$D_REPO"' EXIT
git -C "$D_REPO" init -q; git -C "$D_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m '[VEL-1] x'
git -C "$D_REPO" -c user.name=t -c user.email=t@t tag -m t v1.0.0
D_LINES=$(grep -E '^[[:space:]]+GIT_LOG=\$\(git log "\$\{TAG\}"' "$R01")
expect "D: tag commit under log.decorate=short still yields its ticket" "VEL-1" "$(cd "$D_REPO" && git config log.decorate short && TAG=v1.0.0 PREFIX=VEL && eval "$D_LINES" && printf '%s\n' "$GIT_LOG" | sed -nE "s/^[0-9a-f]+ \[(${PREFIX}-[0-9]+)\].*/\1/p")"
check "01 states the leading-tag rule" 'Only the leading `\[PREFIX-N\]` tag counts' "$R01"

# --- Tracker server check: Step 5b (03) and Step 6 / Step 9 (04) (AC1, AC2, AC3)
for f in "$R03" "$R04"; do
    b=$(basename "$f")
    check "$b runs the Tracker server check on the whole mcp__<tracker.mcp>__ prefix" 'mcp__<tracker\.mcp>__`, matching the whole prefix' "$f"
    check "$b sets TRACKER_UP=no when the server is missing" 'TRACKER_UP=no' "$f"
    check "$b gives the missing-server reason" 'tracker server <tracker\.mcp> not available' "$f"
done
check "03 records the fixVersion skip" 'SKIPPED fixVersion on <N> ticket\(s\): tracker server <tracker\.mcp> not available' "$R03"
check "03 records the transition skip" 'SKIPPED transition to released on <N> ticket\(s\): tracker server <tracker\.mcp> not available' "$R03"
check "03 skips the released-status recovery call too" 'including the released-status recovery' "$R03"
lacks "03 drops the blanket best-effort wording" 'All sub-operations are best-effort: failures warn' "$R03"
check "04 records the comment skip" 'SKIPPED "Released as" comment on <N> ticket\(s\): tracker server <tracker\.mcp> not available' "$R04"
check "04 Step 9 lists skipped operations" 'Skipped tracker operations:' "$R04"
check "04 summary has the fixVersion missing-server variant" 'Fix version: .*skipped \(tracker server <tracker\.mcp> not available\)' "$R04"
check "03 fixVersion still runs on tracker.mcp" 'mcp__<tracker\.mcp>__<operations\.editTicket>' "$R03"
check "03 transitions still run on tracker.mcp" 'mcp__<tracker\.mcp>__<operations\.moveStatus>' "$R03"
check "04 comment still runs on tracker.mcp" 'mcp__<tracker\.mcp>__<operations\.addComment>' "$R04"
for f in "$R03" "$R03B" "$R04"; do
    lacks "$(basename "$f") never routes ticket ops to versionMcp" 'mcp__<(tracker\.)?versionMcp>__<operations\.(editTicket|getTransitions|moveStatus|addComment|readTicket)>' "$f"
done

# --- Tracker server check: release notes (03b), local because notes-only skips 5b
check "03b runs the Tracker server check on the whole mcp__<tracker.mcp>__ prefix" 'mcp__<tracker\.mcp>__`, matching the whole prefix' "$R03B"
check "03b keeps the check local for notes-only" 'MODE=notes-only` skips Step 5b' "$R03B"
check "03b skips ticket reads when the server is missing" 'Ticket read skipped: tracker server <tracker\.mcp> not available' "$R03B"
check "03b skips Confluence when the server is missing" 'CONF=skipped:tracker server <tracker\.mcp> not available' "$R03B"

exit "$FAIL"
