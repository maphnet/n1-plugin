#!/usr/bin/env bash
# N1-647: n1_planning_need_override turns a brainstormer `plan` into `direct` for small, low-risk standard-tier tickets.
# Run: bash tests/test_planning_need_override.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/analysis.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID
export N1_HOME="$T/home" ID="PN-1" N1_SESSION_ID=test-session
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM/telemetry"
echo '{"run_id":"run-pn","n1_version":"5.120.0","host":"claude-code","session_id":"test-session"}' > "$MEM/telemetry/telemetry.lock"
EV="$MEM/telemetry/raw/steps/run-pn.jsonl"
events() { [ -f "$EV" ] && wc -l < "$EV" | tr -d ' ' || echo 0; }
last() { tail -1 "$EV" | jq -r "$1"; }

# fx <tier> <file count> <security_relevant|-> <blast_radius|-> [extra brainstorm.md line]
# "-" leaves the signal out; a file count of "none" removes brainstorm.md.
fx() {
    printf -- '---\ntier: %s\ntype: task\n---\n' "$1" > "$MEM/overview.md"
    { echo '# Analysis'; echo '<!-- n1:signals'
      [ "$3" = "-" ] || echo "security_relevant: $3"
      [ "$4" = "-" ] || echo "blast_radius: $4"
      echo '-->'; } > "$MEM/analysis.md"
    if [ "$2" = "none" ]; then rm -f "$MEM/brainstorm.md"; return; fi
    { echo '# Design'; local i; for ((i = 1; i <= $2; i++)); do echo "- lib/f$i.sh"; done
      [ -n "${5:-}" ] && echo "$5"; } > "$MEM/brainstorm.md"
}
route() { n1_planning_need_override "$1"; }

# --- n1_brainstorm_file_count ---
fx standard 3 false medium
eq "count: distinct file tokens" "3" "$(n1_brainstorm_file_count "$MEM/brainstorm.md")"
echo "- lib/f1.sh again" >> "$MEM/brainstorm.md"
eq "count: duplicates counted once" "3" "$(n1_brainstorm_file_count "$MEM/brainstorm.md")"
eq "count: missing file is 0, not clamped to 1" "0" "$(n1_brainstorm_file_count "$MEM/nope.md")"

# --- happy path ---
fx standard 3 false medium
eq "standard, plan, 3 files, safe signals -> direct" "direct" "$(route plan)"
eq "moved run records planning-need true" "planning-need true" "$(last '"\(.id) \(.result)"')"
eq "event: files" "3" "$(last '.signals.files')"
eq "event: threshold" "4" "$(last '.signals.threshold')"
eq "event: tier" "standard" "$(last '.signals.tier')"
eq "event: security_relevant" "false" "$(last '.signals.security_relevant')"
eq "event: blast" "medium" "$(last '.signals.blast')"
eq "event: open_questions" "false" "$(last '.signals.open_questions')"
eq "event: new_abstractions" "false" "$(last '.signals.new_abstractions')"
eq "event: brainstormer_route" "plan" "$(last '.signals.brainstormer_route')"
eq "event: final_route" "direct" "$(last '.signals.final_route')"
fx standard 1 false low
eq "count 1, blast low -> direct" "direct" "$(route plan)"
fx standard 4 false medium
eq "count 4 (threshold) -> direct" "direct" "$(route plan)"

# --- each guard keeps plan ---
fx standard 5 false medium
eq "count 5 keeps plan" "plan" "$(route plan)"
eq "kept run records planning-need false" "planning-need false" "$(last '"\(.id) \(.result)"')"
eq "kept run: final_route plan" "plan" "$(last '.signals.final_route')"
fx standard 0 false medium
eq "count 0 keeps plan" "plan" "$(route plan)"
fx standard none false medium
eq "missing brainstorm.md keeps plan" "plan" "$(route plan)"
fx standard 3 true medium
eq "security_relevant=true keeps plan" "plan" "$(route plan)"
fx standard 3 - medium
eq "security_relevant missing keeps plan" "plan" "$(route plan)"
fx standard 3 false high
eq "blast_radius=high keeps plan" "plan" "$(route plan)"
fx standard 3 false -
eq "blast_radius missing keeps plan" "plan" "$(route plan)"
fx standard 3 false medium '## Open Questions'
eq "open-questions heading keeps plan" "plan" "$(route plan)"
eq "event: open_questions true" "true" "$(last '.signals.open_questions')"
fx standard 3 false medium '<!-- n1:unknown: who owns the cache? -->'
eq "n1:unknown marker keeps plan" "plan" "$(route plan)"
fx standard 3 false medium '### New abstraction: RouteRule'
eq "new-abstraction heading keeps plan" "plan" "$(route plan)"
eq "event: new_abstractions true" "true" "$(last '.signals.new_abstractions')"
fx standard 3 false medium
eq "route already direct stays direct" "direct" "$(route direct)"
eq "direct in, direct out records false (not moved)" "planning-need false" "$(last '"\(.id) \(.result)"')"

# --- non-standard tiers: unchanged, no event ---
for tier in simple complex; do
    fx "$tier" 3 false medium
    BEFORE=$(events)
    eq "$tier tier keeps plan" "plan" "$(route plan)"
    eq "$tier tier records no event" "$BEFORE" "$(events)"
done

[ "$FAIL" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
