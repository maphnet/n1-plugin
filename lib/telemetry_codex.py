#!/usr/bin/env python3
"""Codex telemetry extraction: usage records, session linkage, schema v4.

Codex session logs are JSONL with record types including token_usage_record
(cumulative usage) and session_meta (session identity/linkage).

Usage extraction follows the session-total strategy: the last
token_usage_record per session is the cumulative total. This avoids
double-counting without needing per-response deduplication.

CLI entrypoint for bash integration:
    python3 lib/telemetry_codex.py extract-usage <session_log>
    python3 lib/telemetry_codex.py extract-linkage <session_log>
Output: JSON to stdout.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

SCHEMA_VERSION = 4


def _records(path: str | Path):
    """Yield parsed JSON records from a JSONL file, skipping bad lines."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec


def extract_usage(path: str | Path) -> dict:
    """Extract token usage from a Codex session log.

    Returns a dict with: input_tokens, cached_input_tokens, output_tokens,
    reasoning_tokens, usage_scope, usage_status, parse_failures, model,
    cli_version. Missing numeric fields are None (never 0).
    """
    p = Path(path)
    null_result = {
        "input_tokens": None, "cached_input_tokens": None,
        "output_tokens": None, "reasoning_tokens": None,
        "usage_scope": "session-total", "usage_status": "unknown",
        "parse_failures": 0, "model": None, "cli_version": None,
    }
    if not p.is_file():
        return null_result

    last_usage: dict | None = None
    parse_failures = 0
    model: str | None = None
    cli_version: str | None = None

    try:
        for rec in _records(p):
            rtype = rec.get("type")
            if rtype == "session_meta":
                payload = rec.get("payload") or {}
                if cli_version is None:
                    cli_version = payload.get("cli_version")
                if model is None:
                    model = payload.get("model")
            elif rtype == "token_usage_record":
                payload = rec.get("payload") or {}
                usage = payload.get("usage")
                if isinstance(usage, dict):
                    last_usage = usage
                else:
                    parse_failures += 1
            elif rtype == "response_item":
                payload = rec.get("payload") or {}
                if payload.get("type") == "message" and payload.get("role") == "assistant":
                    if model is None:
                        model = payload.get("model")
    except OSError:
        return null_result

    if last_usage is None:
        return {**null_result, "parse_failures": parse_failures,
                "model": model, "cli_version": cli_version}

    return {
        "input_tokens": last_usage.get("input_tokens"),
        "cached_input_tokens": last_usage.get("cached_input_tokens"),
        "output_tokens": last_usage.get("output_tokens"),
        "reasoning_tokens": last_usage.get("reasoning_tokens"),
        "usage_scope": "session-total",
        "usage_status": "complete" if parse_failures == 0 else "partial",
        "parse_failures": parse_failures,
        "model": model,
        "cli_version": cli_version,
    }


def extract_linkage(path: str | Path) -> dict:
    """Extract session linkage from a Codex session log.

    Returns a dict with: session_id, parent_id, fork_of, reused_from.
    All fields None when unavailable.
    """
    null_result = {
        "session_id": None, "parent_id": None,
        "fork_of": None, "reused_from": None,
    }
    p = Path(path)
    if not p.is_file():
        return null_result

    try:
        for rec in _records(p):
            if rec.get("type") == "session_meta":
                payload = rec.get("payload") or {}
                return {
                    "session_id": payload.get("session_id"),
                    "parent_id": payload.get("parent_id"),
                    "fork_of": payload.get("fork_of"),
                    "reused_from": payload.get("reused_from"),
                }
    except OSError:
        pass
    return null_result


def main() -> int:
    """CLI entrypoint: extract-usage <path> | extract-linkage <path>"""
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} extract-usage|extract-linkage <session_log>",
              file=sys.stderr)
        return 1

    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "extract-usage":
        print(json.dumps(extract_usage(path), separators=(",", ":")))
    elif cmd == "extract-linkage":
        print(json.dumps(extract_linkage(path), separators=(",", ":")))
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
