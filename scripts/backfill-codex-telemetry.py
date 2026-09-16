#!/usr/bin/env python3
"""Backfill existing merged telemetry records with Codex usage data.

Reads existing merged records from $N1_HOME/memory/*/telemetry/runs/*.jsonl,
re-processes any that lack v4 fields using the telemetry_codex module, and
writes updated records. Labels all reconstructed fields.

Usage:
    python3 scripts/backfill-codex-telemetry.py [--n1-home PATH] [--dry-run]
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import telemetry_codex


def find_codex_session(record: dict) -> Path | None:
    """Try to locate the Codex session log for a merged record."""
    # Check session_transcript_path
    stp = record.get("session_transcript_path")
    if stp:
        p = Path(stp)
        if p.is_file():
            # Verify it's a Codex rollout (has session_meta type)
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    first = fh.readline().strip()
                    if first:
                        rec = json.loads(first)
                        if rec.get("type") == "session_meta":
                            return p
            except (OSError, json.JSONDecodeError):
                pass
    return None


def backfill_record(record: dict, session_path: Path) -> dict | None:
    """Backfill a record with Codex usage and linkage. Returns updated record or None."""
    if record.get("schema_version", 0) >= telemetry_codex.SCHEMA_VERSION:
        if record.get("usage_status") not in (None, "unknown"):
            return None  # Already backfilled

    usage = telemetry_codex.extract_usage(str(session_path))
    linkage = telemetry_codex.extract_linkage(str(session_path))

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    record["schema_version"] = telemetry_codex.SCHEMA_VERSION
    record["host"] = record.get("host") or "codex"
    record["cli_version"] = usage["cli_version"]
    record["parser_schema_version"] = telemetry_codex.SCHEMA_VERSION
    record["usage_status"] = usage["usage_status"]
    record["usage_scope"] = usage["usage_scope"]
    record["session_linkage"] = linkage

    # Update summary with session-total usage if available
    summary = record.get("summary") or {}
    if usage["input_tokens"] is not None:
        summary["total_input_tokens"] = usage["input_tokens"]
        summary["total_output_tokens"] = usage["output_tokens"]
        summary["total_cache_read_tokens"] = usage["cached_input_tokens"]
        summary["total_reasoning_tokens"] = usage["reasoning_tokens"]
        summary["codex_model"] = usage["model"]
    else:
        # Mark as unknown — do not fabricate zero
        for k in ("total_input_tokens", "total_output_tokens", "total_cache_read_tokens"):
            if summary.get(k) == 0:
                summary[k] = None
    record["summary"] = summary

    # Label as backfilled
    record["_backfilled"] = True
    record["_backfill_ts"] = ts
    record["_backfill_parse_failures"] = usage["parse_failures"]

    return record


def main() -> int:
    ap = argparse.ArgumentParser(description="Backfill Codex telemetry records to schema v4")
    ap.add_argument("--n1-home", default=None,
                     help="N1_HOME directory (default: auto-detect)")
    ap.add_argument("--dry-run", action="store_true",
                     help="Print what would be updated without writing")
    args = ap.parse_args()

    n1_home = Path(args.n1_home) if args.n1_home else Path.home() / ".n1"
    if not n1_home.is_dir():
        print(f"N1_HOME not found: {n1_home}", file=sys.stderr)
        return 1

    # Find all merged records across all projects
    updated = 0
    skipped = 0
    errors = 0

    for project_dir in sorted(n1_home.iterdir()):
        if not project_dir.is_dir():
            continue
        runs_dirs = list(project_dir.glob("memory/*/telemetry/runs"))
        for runs_dir in runs_dirs:
            for record_file in sorted(runs_dir.glob("*.jsonl")):
                try:
                    content = record_file.read_text(encoding="utf-8").strip()
                    if not content:
                        continue
                    record = json.loads(content)
                except (OSError, json.JSONDecodeError) as e:
                    print(f"  SKIP {record_file}: {e}", file=sys.stderr)
                    errors += 1
                    continue

                session_path = find_codex_session(record)
                if not session_path:
                    skipped += 1
                    continue

                result = backfill_record(record, session_path)
                if result is None:
                    skipped += 1
                    continue

                if args.dry_run:
                    print(f"  WOULD UPDATE {record_file} "
                          f"(usage_status={result['usage_status']}, "
                          f"input={result.get('summary', {}).get('total_input_tokens')})")
                else:
                    record_file.write_text(
                        json.dumps(result, separators=(",", ":")) + "\n",
                        encoding="utf-8")
                    print(f"  UPDATED {record_file}", file=sys.stderr)
                updated += 1

    label = "Would update" if args.dry_run else "Updated"
    print(f"\n{label}: {updated}, Skipped: {skipped}, Errors: {errors}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
