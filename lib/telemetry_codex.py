#!/usr/bin/env python3
"""Codex telemetry extraction: usage records, session linkage, schema v5.

Codex session logs are JSONL with session totals in ``thread_token_usage``
and request totals in ``usage``. Descendant discovery follows the explicit
read-only ``thread_spawn_edges`` SQLite graph.

CLI entrypoint for bash integration:
    python3 lib/telemetry_codex.py extract-usage <session_log>
    python3 lib/telemetry_codex.py extract-usage-tree <session_log> [state_db]
    python3 lib/telemetry_codex.py extract-linkage <session_log>
Output: JSON to stdout.
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
from pathlib import Path

SCHEMA_VERSION = 5

_USAGE_FIELDS = {
    "input_tokens": "input_tokens",
    "cached_input_tokens": "cached_input_tokens",
    "cache_creation_tokens": "cache_write_input_tokens",
    "output_tokens": "output_tokens",
    "reasoning_tokens": "reasoning_output_tokens",
    "total_tokens": "total_tokens",
}


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

    Prefer the final ``thread_token_usage`` in current Codex records. Its
    ``usage`` sibling describes only the final request. Per-request records
    are summed only when stable response IDs make deduplication possible;
    older formats use their final cumulative value.
    """
    p = Path(path)
    null_result = {
        "input_tokens": None, "cached_input_tokens": None,
        "cache_creation_tokens": None, "output_tokens": None,
        "reasoning_tokens": None, "total_tokens": None,
        "usage_scope": "session-total", "usage_status": "unknown",
        "parse_failures": 0, "model": None, "cli_version": None,
    }
    if not p.is_file():
        return null_result

    request_usages: dict[str, dict] = {}
    legacy_usages: list[dict] = []
    thread_usages: list[dict] = []
    legacy_event_usages: list[dict] = []
    parse_failures = 0
    model: str | None = None
    cli_version: str | None = None

    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
          for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                parse_failures += 1
                continue
            if not isinstance(rec, dict):
                parse_failures += 1
                continue
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
                    if "thread_token_usage" in payload or payload.get('response_id'):
                        thread_usage = payload.get("thread_token_usage")
                        if isinstance(thread_usage, dict) and thread_usage:
                            thread_usages.append(thread_usage)
                        response_id = payload.get("response_id")
                        if isinstance(response_id, str) and response_id:
                            request_usages[response_id] = usage
                        elif not thread_usage:
                            parse_failures += 1
                    else:
                        legacy_usages.append(usage)
                elif isinstance(payload.get("thread_token_usage"), dict):
                    thread_usages.append(payload["thread_token_usage"])
                else:
                    parse_failures += 1
            elif rtype == "event_msg":
                payload = rec.get("payload") or {}
                if payload.get("type") == "token_count":
                    usage = (payload.get("info") or {}).get("total_token_usage")
                    if isinstance(usage, dict):
                        legacy_event_usages.append(usage)
            elif rtype == "response_item":
                payload = rec.get("payload") or {}
                if payload.get("type") == "message" and payload.get("role") == "assistant":
                    if model is None:
                        model = payload.get("model")
    except OSError:
        return null_result

    if thread_usages:
        usages, cumulative = thread_usages[-1:], True
    elif request_usages:
        usages, cumulative = list(request_usages.values()), False
    elif legacy_usages:
        usages, cumulative = legacy_usages[-1:], True
    elif legacy_event_usages:
        usages, cumulative = legacy_event_usages[-1:], True
    else:
        return {**null_result, "parse_failures": parse_failures,
                "model": model, "cli_version": cli_version}

    values = {}
    incomplete = False
    for output, source in _USAGE_FIELDS.items():
        # ``reasoning_tokens`` is the pre-0.154 spelling.
        source = source if any(source in usage for usage in usages) else (
            "reasoning_tokens" if output == "reasoning_tokens" else source)
        nums = [usage.get(source) for usage in usages]
        if all(isinstance(n, int) and not isinstance(n, bool) and n >= 0 for n in nums):
            values[output] = sum(nums) if not cumulative else nums[-1]
        else:
            values[output] = None
            incomplete = True

    return {
        **values,
        "usage_scope": "session-total",
        "usage_status": "complete" if parse_failures == 0 and not incomplete else "partial",
        "parse_failures": parse_failures,
        "model": model,
        "cli_version": cli_version,
    }


def extract_linkage(path: str | Path) -> dict:
    """Extract session linkage from a Codex session log.

    Returns a dict with: session_id, thread_id, parent_id, fork_of,
    reused_from. ``id``/``parent_thread_id`` are the current Codex names.
    All fields None when unavailable.
    """
    null_result = {
        "session_id": None, "thread_id": None, "parent_id": None,
        "fork_of": None, "reused_from": None,
    }
    p = Path(path)
    if not p.is_file():
        return null_result

    try:
        for rec in _records(p):
            if rec.get("type") == "session_meta":
                payload = rec.get("payload") or {}
                thread_id = payload.get("id") or payload.get("session_id")
                return {
                    "session_id": thread_id,
                    "thread_id": thread_id,
                    "parent_id": payload.get("parent_thread_id") or payload.get("parent_id"),
                    "fork_of": payload.get("forked_from_id") or payload.get("fork_of"),
                    "reused_from": payload.get("reused_from"),
                }
    except OSError:
        pass
    return null_result


def _state_db(path: Path, state_db: str | Path | None) -> Path | None:
    if state_db is not None:
        return Path(state_db)
    for parent in path.resolve().parents:
        if parent.name == "sessions":
            return parent.parent / "state_5.sqlite"
    codex_home = os.environ.get("CODEX_HOME")
    return Path(codex_home) / "state_5.sqlite" if codex_home else Path.home() / ".codex" / "state_5.sqlite"


def _discover_descendants(path: str | Path, state_db: str | Path | None) -> tuple[list[Path], str, int]:
    """Return rollout files for descendants explicitly recorded in SQLite.

    This intentionally follows only ``thread_spawn_edges``; nearby rollout
    files, matching working directories, and timestamps are not ancestry.
    """
    path = Path(path)
    thread_id = extract_linkage(path)["thread_id"]
    db = _state_db(path, state_db)
    if not thread_id or db is None or not db.is_file():
        return [], "unavailable", 0
    try:
        conn = sqlite3.connect(f"file:{db.resolve()}?mode=ro", uri=True)
        try:
            rows = conn.execute("""
                WITH RECURSIVE descendants(thread_id) AS (
                    SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id = ?
                    UNION
                    SELECT edge.child_thread_id
                    FROM thread_spawn_edges AS edge
                    JOIN descendants ON edge.parent_thread_id = descendants.thread_id
                )
                SELECT descendants.thread_id, threads.rollout_path
                FROM descendants LEFT JOIN threads ON threads.id = descendants.thread_id
            """, (thread_id,)).fetchall()
        finally:
            conn.close()
    except sqlite3.Error:
        return [], "unavailable", 0
    seen = set()
    paths = []
    missing = 0
    for descendant_id, rollout_path in rows:
        if descendant_id == thread_id or not rollout_path:
            missing += descendant_id != thread_id
            continue
        rollout = Path(rollout_path)
        try:
            key = rollout.resolve()
            root_key = path.resolve()
        except OSError:
            key = rollout
            root_key = path
        if key == root_key:
            continue
        if rollout.is_file() and key not in seen:
            seen.add(key)
            paths.append(rollout)
        elif not rollout.is_file():
            missing += 1
    return sorted(paths), "available", missing


def discover_descendant_paths(path: str | Path, state_db: str | Path | None = None) -> list[Path]:
    """Return rollout files for descendants explicitly recorded in SQLite."""
    return _discover_descendants(path, state_db)[0]


def extract_usage_tree(path: str | Path, state_db: str | Path | None = None) -> dict:
    """Aggregate one rollout and its explicit SQLite descendants."""
    descendants, discovery_status, missing = _discover_descendants(path, state_db)
    paths = [Path(path), *descendants]
    usages = [extract_usage(session_path) for session_path in paths]
    result = dict(usages[0])
    result["root_usage"] = dict(usages[0])
    for field in _USAGE_FIELDS:
        values = [usage[field] for usage in usages]
        result[field] = sum(values) if all(isinstance(v, int) and not isinstance(v, bool) for v in values) else None
    result["parse_failures"] = sum(usage["parse_failures"] for usage in usages)
    statuses = [usage["usage_status"] for usage in usages]
    result["usage_status"] = (
        "complete" if all(status == "complete" for status in statuses)
        else "unknown" if all(status == "unknown" for status in statuses)
        else "partial"
    )
    result["session_count"] = len(paths)
    result["missing_session_count"] = missing
    result["discovery_status"] = discovery_status
    result["headless_coverage"] = "unknown"
    if discovery_status == "unavailable":
        result["usage_scope"] = "root-only"
    elif len(paths) > 1 or missing:
        result["usage_scope"] = "session-tree"
    if missing or discovery_status == "unavailable":
        result["usage_status"] = "partial" if result["usage_status"] != "unknown" else "unknown"
    return result


def main() -> int:
    """CLI entrypoint: extract-usage[-tree] <path> | extract-linkage <path>."""
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} extract-usage|extract-usage-tree|extract-linkage <session_log> [state_db]",
              file=sys.stderr)
        return 1

    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "extract-usage":
        print(json.dumps(extract_usage(path), separators=(",", ":")))
    elif cmd == "extract-usage-tree":
        print(json.dumps(extract_usage_tree(path, sys.argv[3] if len(sys.argv) > 3 else None), separators=(",", ":")))
    elif cmd == "extract-linkage":
        print(json.dumps(extract_linkage(path), separators=(",", ":")))
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
