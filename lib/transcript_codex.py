#!/usr/bin/env python3
"""Codex rollout transcript reader for n1-benchmark.

Rollouts live at ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Each line is
{"timestamp", "ordinal", "type", "payload"}; conversation content is in records of type
"response_item" whose payload.type is "message" (role user/assistant/developer),
"function_call" or "custom_tool_call". Records of other types (session_meta, event_msg,
token_usage_record, compacted, ...) carry no turns.

iter_events() yields the same normalized events as scripts/benchmark.py yields for
Claude Code transcripts:
  {"kind": "user" | "assistant" | "tool_call", "timestamp": str | None,
   "text": str, "tool": str | None, "asked": bool}
Injected user records (AGENTS.md instructions, <environment_context>, <skills_instructions>,
<turn_aborted>, ...) are dropped: they are not typed by the human.
"""

import json
from pathlib import Path

INJECTED_PREFIXES = ("<", "# AGENTS.md instructions")
ASK_TOOLS = {"request_user_input"}
TEXT_TYPES = ("input_text", "output_text", "text")


def _text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") in TEXT_TYPES]
        return "\n".join(p for p in parts if p)
    return ""


def _records(path):
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


def iter_events(path):
    for rec in _records(path):
        if rec.get("type") != "response_item":
            continue
        payload = rec.get("payload") or {}
        ts = rec.get("timestamp")
        ptype = payload.get("type")
        if ptype == "message":
            role, text = payload.get("role"), _text(payload.get("content"))
            if role == "user":
                if not text.strip() or text.lstrip().startswith(INJECTED_PREFIXES):
                    continue
                yield {"kind": "user", "timestamp": ts, "text": text, "tool": None, "asked": False}
            elif role == "assistant":
                yield {"kind": "assistant", "timestamp": ts, "text": text, "tool": None, "asked": False}
        elif ptype in ("function_call", "custom_tool_call"):
            name = payload.get("name") or ""
            yield {"kind": "tool_call", "timestamp": ts, "text": "", "tool": name, "asked": name in ASK_TOOLS}


def session_files(sessions_dir):
    return sorted(Path(sessions_dir).glob("*/*/*/rollout-*.jsonl"))


def session_cwd(path):
    """cwd from the session_meta record (always the first line), or None."""
    for rec in _records(path):
        if rec.get("type") == "session_meta":
            return (rec.get("payload") or {}).get("cwd")
        return None
    return None
