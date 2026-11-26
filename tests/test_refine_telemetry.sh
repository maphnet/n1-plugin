#!/usr/bin/env bash
# N1-652: n1_emit_refine_question writes run-less refine events (enums and bools only);
# telemetry_analyzer.py refine aggregates them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
unset N1_RUN_ID N1_VERSION
export N1_HOME="$T/proj" N1_STATE_DIR="$T/state"
source "$ROOT/lib/telemetry.sh"
FAIL=0
ok() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; FAIL=1; fi
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

F1="$N1_HOME/memory/T-1/telemetry/refine.jsonl"

# --- emission: one asked, one auto-decided, one overridden point
n1_emit_refine_question T-1 decision A false true recommended false 1
n1_emit_refine_question T-1 decision A false true auto-decided false 1
n1_emit_refine_question T-1 decision A false true overridden false 1
ok "three events written to the ticket telemetry dir" "$(lines "$F1")" 3

RES=$(python3 - "$F1" <<'PY' 2>&1
import json, sys
want = {"event", "ticket_id", "kind", "tier", "stop_list", "had_recommendation",
        "answer", "list_mode", "tickets", "timestamp"}
answers = []
for line in open(sys.argv[1]):
    e = json.loads(line)
    assert set(e) == want, sorted(e)
    assert e["event"] == "refine_question" and e["ticket_id"] == "T-1" and e["kind"] == "decision"
    assert e["tier"] == "A" and e["stop_list"] is False and e["had_recommendation"] is True
    assert e["list_mode"] is False and e["tickets"] == 1 and e["timestamp"].endswith("Z")
    answers.append(e["answer"])
print(",".join(answers))
PY
)
ok "fields are exactly the enum/bool set (no text); answers in order" "$RES" "recommended,auto-decided,overridden"

# --- invalid input writes nothing and returns 0
n1_emit_refine_question T-1 decision A false true "I prefer option two" false 1; ok "free-text answer value returns 0" "$?" 0
n1_emit_refine_question T-1 decision D false true recommended false 1
n1_emit_refine_question T-1 question A false true recommended false 1
n1_emit_refine_question T-1 decision A maybe true recommended false 1
n1_emit_refine_question T-1 decision A false true recommended false x
n1_emit_refine_question T-1 decision A false true
n1_emit_refine_question ../x decision A false true recommended false 1
ok "invalid input writes nothing" "$(lines "$F1")" 3
ok "traversal ticket creates nothing" "$([ -e "$N1_HOME/x" ] && echo yes || echo no)" no
( unset N1_HOME; n1_emit_refine_question T-9 decision A false true recommended false 1 ); ok "no N1_HOME returns 0" "$?" 0

# --- analyzer: T-1 has recommended/auto-decided/overridden; T-2 adds one other-option A question
# and one actions question; one malformed line is skipped.
n1_emit_refine_question T-2 decision A true true other-option true 2
n1_emit_refine_question T-2 actions "" false true recommended true 2
echo 'not json' >> "$F1"
OUT=$(python3 "$ROOT/scripts/telemetry_analyzer.py" refine --n1-root "$T" 2>&1)
RES=$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin); a = d["by_tier"]["A"]
print(d["events"], d["malformed"], d["refined_tickets"], d["asked"], d["questions_per_ticket"],
      a["asked"], a["with_recommendation"], a["recommended_share"], a["auto_decided"], a["overridden"],
      a["override_rate"], d["by_kind"]["actions"], d["by_tier"]["B"]["recommended_share"], d["override_rate"])' 2>&1)
ok "analyzer aggregates per ticket, tier and kind" "$RES" "5 1 2 3 1.5 2 2 0.5 1 1 0.5 1 None 0.5"

OUT=$(python3 "$ROOT/scripts/telemetry_analyzer.py" refine --n1-root "$T" --since 2999-01-01 2>&1)
RES=$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["events"], d["questions_per_ticket"])' 2>&1)
ok "--since window excludes older events" "$RES" "0 None"

exit $FAIL
