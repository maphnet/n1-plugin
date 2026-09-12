#!/usr/bin/env python3
"""Assemble an opt-in, relocatable runtime-review preview package."""

import argparse
from pathlib import Path
import hashlib
import json
import shutil
import sys


SOURCE_ROOT = Path(__file__).resolve().parents[1]
HOSTS = {"claude-code", "codex", "pi"}
COMMON_FILES = (Path("lib/config.sh"), Path("lib/runtime-review.sh"))
COMMON_TREES = (Path("lib/runtime_review"), Path("runtime/review"))
CLAUDE_FILES = (Path("README.md"), Path("pipeline.json"))
CLAUDE_TREES = (
    Path(".claude-plugin"), Path("agents"), Path("defaults"), Path("hooks"),
    Path("lib"), Path("references"), Path("scripts"), Path("skills"),
    Path("runtime/review"), Path("adapters/claude-code/preview"),
)


def _is_generated(name: str) -> bool:
    return name in {"node_modules", "__pycache__"} or name.endswith(".pyc")


def _ignore_generated(_directory: str, names: list[str]) -> set[str]:
    return {name for name in names if _is_generated(name)}


def _reject_source_symlinks(path: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"source symlink is not allowed: {path}")
    if path.is_dir():
        for child in path.iterdir():
            if _is_generated(child.name):
                continue
            if child.is_symlink():
                raise ValueError(f"source symlink is not allowed: {child}")
            if child.is_dir():
                _reject_source_symlinks(child)


def build_package(host: str, destination: Path) -> Path:
    """Copy one host runtime and its shared resources into a new directory."""
    if host not in HOSTS:
        raise ValueError(f"unknown host: {host}")
    destination = Path(destination)
    if not destination.is_absolute():
        raise ValueError("destination must be absolute")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    source_root = SOURCE_ROOT.resolve()
    resolved_destination = destination.resolve()
    if resolved_destination == source_root or source_root in resolved_destination.parents:
        raise ValueError("destination must be outside the source tree")

    if host == "claude-code":
        files = CLAUDE_FILES
        trees = CLAUDE_TREES
    else:
        files = COMMON_FILES
        trees = COMMON_TREES + (Path("adapters") / host / "preview",)
    sources = files + trees
    for relative in sources:
        _reject_source_symlinks(source_root / relative)

    destination.mkdir(parents=True)
    for relative in files:
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_root / relative, target)
    for relative in trees:
        shutil.copytree(
            source_root / relative,
            destination / relative,
            symlinks=False,
            ignore=_ignore_generated,
        )
    files = {
        path.relative_to(destination).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(destination.rglob("*"))
        if path.is_file()
    }
    evidence = {"schemaVersion": 1, "host": host, "files": files}
    (destination / "package-evidence.json").write_text(
        json.dumps(evidence, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return destination


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--host", required=True, choices=sorted(HOSTS))
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        package = build_package(args.host, args.destination)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(package)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
