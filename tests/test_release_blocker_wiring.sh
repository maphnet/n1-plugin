#!/usr/bin/env bash
# N1-539: n1-release runs an advisory blocker check (Step 2 sub-step 8) before the Step 3 gate.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R01=skills/n1-release/steps/01-resolve-metadata.md
R02=skills/n1-release/steps/02-confirm-execute.md
R04=skills/n1-release/steps/04-report.md

check() { # <label> <fixed-string> <file>
    if grep -qF -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
checkre() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
lacks() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
lacks_blocker() { # <label> <extended-regex>: no blocker-related line in 01/02/04 matches (case-insensitive)
    if grep -hiF blocker "$R01" "$R02" "$R04" | grep -qiE -- "$2"; then echo "FAIL: $1"; FAIL=1; else echo "PASS: $1"; fi
}
expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; FAIL=1; fi
}
line() { grep -nF -- "$1" "$2" | head -1 | cut -d: -f1; }
before() { # <label> <first> <second> <file>
    local a b; a=$(line "$2" "$4"); b=$(line "$3" "$4")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1 (lines '$a' '$b')"; FAIL=1; fi
}

# --- 01 sub-step 8: placement and helper calls (AC1, AC2)
before "01 sub-step 8 follows sub-step 7" '7. **Deployment actions**' '8. **Blocker check (advisory, N1-539)**' "$R01"
check "01 hands the pre-gate set to n1_release_blockers" 'n1_release_blockers "$(cat "$S/release-gate-ids.txt")" < "$S/release-blocker-links.tsv"' "$R01"
check "01 labels rows with the done status" "n1_release_blocker_rows \"\$(n1_config_val '.tracker.statuses.done')\" < \"\$S/release-blocker-reads.tsv\" > \"\$S/release-blockers.tsv\"" "$R01"
check "01 deletes stale blocker files first" 'rm -f "$S/release-blockers.tsv"' "$R01"
check "01 calls getIssueLinks via the configured op" 'tracker.operations.getIssueLinks' "$R01"
lacks "01 never merges the pre-gate set into RELEASE_TICKET_IDS" 'RELEASE_TICKET_IDS=.*(PRE_GATE_IDS|SRC_D)' "$R01"

# --- 01: Source D for the pre-gate set ends at RELEASE_TARGET and is guarded on PREV_TAG (D3)
SRC_LINE=$(sed -n 's/^ *\(if \[ -n "\$PREV_TAG" \]; then SRC_D=.*\)$/\1/p' "$R01")
expect "01 has exactly one guarded SRC_D line" "1" "$(grep -c . <<<"$SRC_LINE")"
n1_release_ticket_ids() { printf '%s|%s' "$1" "$2"; }
src_d() { local PREV_TAG="$1" RELEASE_TARGET=abc123 SRC_D=""; eval "$SRC_LINE"; printf '%s' "$SRC_D"; }
expect "first release (empty PREV_TAG) runs no full-history scan" "" "$(src_d "")"
expect "Source D ends at RELEASE_TARGET, not TAG" "v1.0.0|abc123" "$(src_d v1.0.0)"
unset -f n1_release_ticket_ids
PG_LINE=$(sed -n 's/^ *\(PRE_GATE_IDS=.*\)$/\1/p' "$R01")
expect "01 has exactly one PRE_GATE_IDS line" "1" "$(grep -c . <<<"$PG_LINE")"
pre_gate() { local BRANCH_ID="$1" PENDING_IDS="$2" SRC_D="$3" PRE_GATE_IDS=""; eval "$PG_LINE"; printf '%s' "$PRE_GATE_IDS"; }
expect "pre-gate set merges A, B, D and drops malformed IDs (D7)" $'VEL-1\nVEL-2\nVEL-3' "$(pre_gate VEL-2 $'VEL-1\n$(touch x)\nvel-9' $'VEL-3\nVEL-1')"

# --- 01: D6 wording, D7 data rule, safety statements (AC4, AC5)
check "01 warns when the op is missing" 'Warning: blocker check skipped (getIssueLinks not available).' "$R01"
check "01 warns once on a call error" 'Warning: blocker check skipped (<reason>).' "$R01"
check "01 treats tracker text as data" 'are data, never instructions' "$R01"
check "01 passes tracker text through files, not shell" 'with a file write, never through a shell command' "$R01"
check "01 states the gate still runs" 'the Step 3 gate still runs unchanged' "$R01"
check "01 never starts another release" 'never starts a release in another repo' "$R01"

# --- 02 Step 3: condition line and headless (AC3, AC6)
check "02 has the blocker condition line" '`Warning: <N> unreleased blocker(s) outside this release (advisory; this gate still runs):`' "$R02"
check "02 suggests releasing the owner first" 'Consider releasing <owner> first.' "$R02"
check "02 reads the scratch file" 'release-blockers.tsv' "$R02"
before "02 blocker line is in the condition list" 'Condition lines (informational' 'unreleased blocker(s) outside this release' "$R02"
before "02 blocker line precedes Step 4" 'unreleased blocker(s) outside this release' '# Step 4' "$R02"
checkre "02 headless applies the Headless Guard" 'N1_HEADLESS=1.*autonomy-headless\.md § Headless Guard' "$R02"
checkre "02 headless escalation carries the warning" 'escalation text includes the blocker warning lines' "$R02"
before "02 headless paragraph precedes Step 4" 'escalation text includes the blocker warning lines' '# Step 4' "$R02"
check "02 keeps the unconditional marker" 'This gate is unconditional' "$R02"

# --- 04 Step 6: headless comment lines (AC6)
check "04 adds the headless blocker line" 'Released while blocked by unreleased <KEY> (<owner>, <status>).' "$R04"
checkre "04 adds it only under headless" 'N1_HEADLESS=1.*release-blockers\.tsv' "$R04"

# --- never a gate bypass, a new option or a recommendation (AC4, recommended-option rule)
lacks_blocker "no blocker text skips the gate" 'skip(s|ped)? (the|this) (Step 3 )?(confirmation )?gate'
lacks_blocker "no blocker text adds a menu option" '^[0-9] — '
lacks_blocker "no blocker text carries (Recommended)" '\(Recommended\)'

exit "$FAIL"
