#!/usr/bin/env python3
"""Fail closed before the shared review bridge can prepare a Codex preview run."""

import json
from pathlib import Path
import re
import sys


TARGET = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*\Z")
CAPABILITIES = ("readSearchEnforced", "isolatedContext", "lifecycleControl")


def unsupported(target: str, record: dict) -> dict:
    """Build the only currently supported result from package-owned evidence."""
    capabilities = record.get("capabilities") if type(record) is dict else None
    if type(capabilities) is not dict:
        capabilities = {}
    reasons = {
        name: capabilities.get(name, "unverified: packaged qualification record is invalid")
        for name in CAPABILITIES
    }
    models = record.get("models") if type(record) is dict else None
    reasons["models"] = (models if type(models) is str and models
                         else "unverified: packaged qualification record is invalid")
    return {"status": "unsupported", "target": target, "reasons": reasons}


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or not TARGET.fullmatch(argv[0]):
        print(json.dumps({"status": "unsupported", "reason": "target must be explicit owner/repo#123"}))
        return 2
    try:
        record = json.loads((Path(__file__).parent / "qualification.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        record = None
    print(json.dumps(unsupported(argv[0], record), ensure_ascii=False))
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
