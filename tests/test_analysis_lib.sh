#!/usr/bin/env bash
# N1-436: lib/analysis.sh runs the analysis step's entry and post-SA blocks.
# Run: bash tests/test_analysis_lib.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" N1_ROOT="$REPO_ROOT"
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1 (missing: $3)"; fi; }
lacks() { if [[ "$2" == *"$3"* ]]; then no "$1 (unexpected: $3)"; else ok "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected=[$2] actual=[$3])"; fi; }

source "$REPO_ROOT/lib/config.sh"; source "$REPO_ROOT/lib/step.sh"; source "$REPO_ROOT/lib/validation.sh"
source "$REPO_ROOT/lib/analysis.sh"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID
export N1_HOME="$T/home" ID="AN-1" N1_SESSION_ID=test-session
MEM="$N1_HOME/memory/$ID"; mkdir -p "$MEM/telemetry"
echo '{"run_id":"run-an","n1_version":"5.77.0","host":"claude-code","session_id":"test-session"}' > "$MEM/telemetry/telemetry.lock"
EV="$MEM/telemetry/raw/steps/run-an.jsonl"
last_decision() { tail -1 "$EV" 2>/dev/null | jq -r '"\(.id) \(.result)"'; }
ctx_val() { ( eval "$1=__unset__"; n1_read_context; eval "echo \"\$$1\"" ); }

# --- n1_analysis_entry ---
printf -- '---\ntier: simple\ntype: task\n---\n' > "$MEM/overview.md"
printf '<!-- n1:signals description_quality=adequate -->\n' > "$MEM/ticket.md"
OUT=$(n1_analysis_entry 2>&1)
has "entry: simple task is lite" "$OUT" "LITE_MODE=true CACHE_STATE="
has "entry: prints RELATED_ENABLED" "$OUT" "RELATED_ENABLED="
has "entry: prints SA_MODEL and SA_EFFORT" "$OUT" "SA_MODEL="
has "entry: prints SNAPSHOT_PATH" "$OUT" "SNAPSHOT_PATH=$(n1_snapshot_path "$N1_HOME")"
has "entry: prints PROJECT_MAP_PATH" "$OUT" "PROJECT_MAP_PATH=$(n1_project_map_path "$N1_HOME")"
eq "entry: records lite-analysis-gate" "lite-analysis-gate true" "$(last_decision)"
eq "entry: persists LITE_MODE" "true" "$(ctx_val LITE_MODE)"
eq "entry: persists TIER" "simple" "$(ctx_val TIER)"

printf -- '---\ntier: standard\ntype: task\n---\n' > "$MEM/overview.md"
echo '{"analysisCache":{"enabled":false}}' > "$N1_HOME/config.json"
OUT=$(n1_analysis_entry 2>&1)
has "entry: standard tier is not lite; cache off is cold" "$OUT" "LITE_MODE=false CACHE_STATE=cold"
eq "entry: records lite-analysis-gate false" "lite-analysis-gate false" "$(last_decision)"
rm -f "$N1_HOME/config.json"

# --- n1_analysis_finalize ---
fin_fixture() { # <tier>
    printf -- '---\ntier: %s\ntype: task\n---\n' "$1" > "$MEM/overview.md"
    printf '# Analysis\n<!-- n1:resolved: answered from code -->\n' > "$MEM/analysis.md"
    ( TIER="$1"; TYPE=task; DESC_QUALITY=adequate; LITE_MODE=false; SIMPLE_PATH=false; n1_write_context )
    : > "$MEM/xrepo-pending.tsv"
}
SA=$(printf '%s\n' 'Summary line' \
    'n1:signals blast_radius=low files_changed=1 security_relevant=false ticket_contradictions=2' \
    'LITE_ESCALATED: touches auth' 'context: |' '  ctx line one' '  ctx line two' 'done')

fin_fixture simple
OUT=$(printf '%s\n' "$SA" | n1_analysis_finalize "https://tracker/AN-1" 2>&1)
has "finalize: missing snapshot reported" "$OUT" "Snapshot persistence failed."
has "finalize: missing project map reported (cold, non-lite)" "$OUT" "Project map persistence failed."
has "finalize: LITE_ESCALATED relayed" "$OUT" "LITE_ESCALATED: touches auth"
has "finalize: contradictions line" "$OUT" "Ticket contradictions found: 2"
has "finalize: simple-path line" "$OUT" "Simple-path: skipping brainstorm and plan"
has "finalize: SELF_RESOLVED and SIMPLE_PATH printed" "$OUT" "SELF_RESOLVED=1 SIMPLE_PATH=true"
has "finalize: context block delimited" "$OUT" $'CONTEXT_BLOCK<<\nctx line one\nctx line two\nCONTEXT_BLOCK>>'
eq "finalize: signals written" "low" "$(n1_read_signal "$MEM/analysis.md" blast_radius)"
eq "finalize: self_resolved signal written" "1" "$(n1_read_signal "$MEM/analysis.md" self_resolved)"
eq "finalize: ticket_url frontmatter written" "https://tracker/AN-1" "$(n1_read_frontmatter "$MEM/overview.md" ticket_url)"
eq "finalize: SIMPLE_PATH persisted" "true" "$(ctx_val SIMPLE_PATH)"
eq "finalize: records simple-path" "simple-path true" "$(last_decision)"
if [ -e "$MEM/xrepo-pending.tsv" ]; then no "finalize: xrepo-pending reset"; else ok "finalize: xrepo-pending reset"; fi

fin_fixture standard
SNAP=$(n1_snapshot_path "$N1_HOME"); mkdir -p "$(dirname "$SNAP")"; printf '# snap\nbody\n' > "$SNAP"
OUT=$(printf 'SNAPSHOT_DRIFT: lib moved\nn1:signals blast_radius=medium files_changed=5\n' | n1_analysis_finalize 2>&1)
has "finalize: drift relayed" "$OUT" "SNAPSHOT_DRIFT: lib moved"
if [ -e "$SNAP" ]; then no "finalize: drift deletes snapshot"; else ok "finalize: drift deletes snapshot"; fi
lacks "finalize: snapshot present at check time is no failure" "$OUT" "Snapshot persistence failed."
has "finalize: standard tier is not simple path" "$OUT" "SIMPLE_PATH=false"
lacks "finalize: no simple-path line" "$OUT" "Simple-path:"
lacks "finalize: no contradictions line at 0" "$OUT" "Ticket contradictions"
lacks "finalize: no context block when none returned" "$OUT" "CONTEXT_BLOCK<<"
eq "finalize: records simple-path false" "simple-path false" "$(last_decision)"

# --- step wiring: execute the step's own fences so the call text itself is tested ---
STEP="$REPO_ROOT/skills/n1-start/steps/analysis.md"
fence() { awk -v n="$2" '/^```bash$/{c++; if (c==n) {f=1; next}} /^```$/{f=0} f' "$1" | sed '\#^source ~/.n1/preamble.sh$#d'; }
n1_step_begin() { :; }; n1_step_end() { :; }
printf -- '---\ntier: simple\ntype: task\n---\n' > "$MEM/overview.md"
printf '<!-- n1:signals description_quality=adequate -->\n' > "$MEM/ticket.md"
OUT=$( eval "$(fence "$STEP" 1)" 2>&1 )
has "wiring: entry fence prints LITE_MODE" "$OUT" "LITE_MODE=true CACHE_STATE="
has "wiring: entry fence prints SA_MODEL" "$OUT" "SA_MODEL="
fin_fixture simple; printf '%s\n' "$SA" > "$MEM/sa-return.md"
OUT=$( eval "$(fence "$STEP" 3 | sed 's/<ticket URL, or empty>//')" 2>&1 )
has "wiring: finalize fence reads sa-return.md" "$OUT" "SELF_RESOLVED=1 SIMPLE_PATH=true"
has "wiring: finalize fence prints the context block" "$OUT" "CONTEXT_BLOCK<<"

exit $FAIL
