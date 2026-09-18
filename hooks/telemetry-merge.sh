#!/usr/bin/env bash
set -euo pipefail

RUN_ID="${1:?Usage: telemetry-merge.sh <run_id> <telemetry_dir>}"
TELEM_DIR="${2:?Usage: telemetry-merge.sh <run_id> <telemetry_dir>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for PY in python3 python; do
    command -v "$PY" >/dev/null 2>&1 && break
done
if ! command -v "$PY" >/dev/null 2>&1; then
    echo "telemetry-merge: Python 3 is required for consistent telemetry accounting" >&2
    exit 1
fi

LOCK_FILE="${TELEM_DIR}/telemetry.lock"
[ ! -f "${TELEM_DIR}/locks/${RUN_ID}.json" ] || LOCK_FILE="${TELEM_DIR}/locks/${RUN_ID}.json"
N1_VERSION=$("$PY" -c '
import json, sys
try: print(json.load(open(sys.argv[1], encoding="utf-8")).get("n1_version") or "")
except (OSError, ValueError): pass
' "$LOCK_FILE" 2>/dev/null || true)
PROJECT_NAME=""
if [ -n "${N1_HOME:-}" ]; then
    PROJECT_NAME=$(basename "$N1_HOME")
fi

"$PY" "${SCRIPT_DIR}/telemetry-merge.py" "$RUN_ID" "$TELEM_DIR" \
    --n1-version "$N1_VERSION" --project "$PROJECT_NAME"
echo "Telemetry merged: ${TELEM_DIR}/runs/${RUN_ID}.jsonl" >&2
