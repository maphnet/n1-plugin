#!/usr/bin/env python3
"""Stop hook: nudge step-mode sessions that end without emitting a step result.

Dogfood finding I16: a step session occasionally completes its work but never runs
`n1_emit_step_result`, so the loop falls to tier-3 inference and wastes a whole
iteration. This hook blocks the stop exactly once with a corrective reason; the
one-shot marker (step-result.nudged, keyed by run_id) guarantees no infinite blocks.

Acts only when ALL hold — otherwise exit 0 (fail-open):
  1. N1_RUN_ID is set (only n1-loop step sessions receive it),
  2. a telemetry.lock whose run_id equals N1_RUN_ID exists (active-ticket discovery;
     inactive when telemetry is disabled — accepted limitation, fallback = today's
     tier-2/tier-3 behavior),
  3. step-result.json is missing (the loop deletes it pre-spawn, so absence at stop
     time means no emission happened this step).

Usage: enforce-step-result.py <memory_dir>   (hook payload on stdin)
"""

import json
import os
import sys
from pathlib import Path

REASON = (
    "Step-mode contract: you must run "
    "`n1_emit_step_result <step> <outcome> <next_step> <loop_counter>` "
    "(the bash helper — typing the N1_STEP_RESULT line as text is not sufficient) "
    "before ending. Compute next_step from the Step Mode Routing table in SKILL.md."
)


def find_ticket_dir(memory_dir: Path, run_id: str) -> Path | None:
    try:
        locks = sorted(memory_dir.glob("*/telemetry/telemetry.lock"),
                       key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return None
    for lock in locks:
        try:
            data = json.loads(lock.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if data.get("run_id") == run_id:
            return lock.parent.parent
    return None


def main() -> int:
    run_id = os.environ.get("N1_RUN_ID", "")
    if not run_id:
        return 0
    try:
        memory_dir = Path(sys.argv[1])
        payload = json.loads(sys.stdin.read())
    except (IndexError, json.JSONDecodeError, ValueError):
        return 0
    if payload.get("stop_hook_active"):
        return 0

    ticket_dir = find_ticket_dir(memory_dir, run_id)
    if ticket_dir is None:
        return 0
    if (ticket_dir / "step-result.json").exists():
        return 0

    marker = ticket_dir / "step-result.nudged"
    try:
        if marker.exists() and marker.read_text(encoding="utf-8").strip() == run_id:
            return 0
        marker.write_text(run_id, encoding="utf-8")
    except OSError:
        return 0

    print(json.dumps({"decision": "block", "reason": REASON}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
