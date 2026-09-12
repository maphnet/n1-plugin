"""Bounded, literal-only reader for controller-selected snapshot roots.

Adapters must bind the root outside model-controlled arguments. This module
does not grant authority to choose a root, launch a shell, or load project code.
"""

import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_TOTAL_BYTES = 100 * 1024 * 1024
MAX_MATCHES = 10000


def safe_relative(name):
    if not isinstance(name, str) or not name or '\x00' in name:
        raise ValueError('source path escapes snapshot')
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or '..' in path.parts:
        raise ValueError('source path escapes snapshot')
    if any(part.lower() == '.git' for part in path.parts):
        raise ValueError('.git access is denied')
    return path


def _root_fd(root):
    """Open every ancestor without following symlinks, including the root."""
    absolute = Path(os.path.abspath(root))
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in absolute.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read_bytes(root, relative):
    parts = safe_relative(relative).parts
    fd = None
    try:
        fd = _root_fd(root)
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(file_fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('source must be a regular file')
            if info.st_size > MAX_FILE_BYTES:
                raise ValueError('file byte limit exceeded')
            data = handle.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise ValueError('file byte limit exceeded')
            return data
    except OSError as exc:
        raise ValueError('source file is inaccessible: ' + relative) from exc
    finally:
        if fd is not None:
            os.close(fd)


def _text(data):
    if b'\x00' in data:
        raise ValueError('binary source is unsupported')
    try:
        return data.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise ValueError('binary or non-UTF-8 source is unsupported') from exc


def read_file(root: Path, relative: str) -> str:
    return _text(_read_bytes(root, relative))


def search_files(root: Path, literal: str) -> list[dict]:
    if not isinstance(literal, str) or not literal:
        raise ValueError('search literal must be nonempty')
    results = []
    total = 0
    output_bytes = 0
    try:
        fd = _root_fd(root)
        os.close(fd)
        def fail(exc):
            raise ValueError('search directory is inaccessible') from exc
        for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
            dirs[:] = sorted(name for name in dirs if name.lower() != '.git'
                             and not (Path(directory) / name).is_symlink())
            for name in sorted(files):
                path = Path(directory) / name
                if name.lower() == '.git' or path.is_symlink():
                    continue
                if not stat.S_ISREG(path.lstat().st_mode):
                    continue
                relative = path.relative_to(root).as_posix()
                data = _read_bytes(root, relative)
                total += len(data)
                if total > MAX_TOTAL_BYTES:
                    raise ValueError('search byte limit exceeded')
                try:
                    text = _text(data)
                except ValueError:
                    continue
                for number, line in enumerate(text.splitlines(), 1):
                    if literal in line:
                        output_bytes += len(line.encode('utf-8')) + len(relative.encode('utf-8')) + 32
                        if len(results) >= MAX_MATCHES or output_bytes > MAX_FILE_BYTES:
                            raise ValueError('search result limit exceeded')
                        results.append({'file': relative, 'line': number, 'text': line})
        return results
    except OSError as exc:
        raise ValueError('search source is inaccessible') from exc


def main(argv=None):
    """Restricted script form: reader.py read|search ROOT VALUE (T6 bridge)."""
    argv = sys.argv[1:] if argv is None else argv
    try:
        if len(argv) != 3 or argv[0] not in ('read', 'search'):
            raise ValueError('expected read|search ROOT VALUE')
        operation, root, value = argv
        result = read_file(Path(root), value) if operation == 'read' else search_files(Path(root), value)
        print(json.dumps(result))
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
