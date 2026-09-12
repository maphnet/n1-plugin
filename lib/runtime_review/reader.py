"""Bounded, literal-only reader for controller-selected snapshot roots.

Adapters must bind the root outside model-controlled arguments. This module
does not grant authority to choose a root, launch a shell, or load project code.
"""

import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys


MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_TOTAL_BYTES = 100 * 1024 * 1024
MAX_MATCHES = 10000
POLICY_KEYS = {'schemaVersion', 'sourceRoot', 'allowedInputPaths'}


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


def search_files(root: Path, literal: str, *, excluded_paths=()) -> list[dict]:
    if not isinstance(literal, str) or not literal:
        raise ValueError('search literal must be nonempty')
    results = []
    total = 0
    output_bytes = 0
    try:
        fd = _root_fd(root)
        os.close(fd)
        excluded = {(info.st_dev, info.st_ino) for info in
                    (Path(path).stat() for path in excluded_paths)}
        def fail(exc):
            raise ValueError('search directory is inaccessible') from exc
        for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
            dirs[:] = sorted(name for name in dirs if name.lower() != '.git'
                             and not (Path(directory) / name).is_symlink())
            for name in sorted(files):
                path = Path(directory) / name
                if name.lower() == '.git' or path.is_symlink():
                    continue
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) in excluded:
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


def _unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('worker policy contains a duplicate key')
        value[key] = item
    return value


def _canonical_absolute(path, label):
    if type(path) is not str or not path or '\x00' in path:
        raise ValueError(label + ' must be an absolute canonical path')
    value = Path(path)
    if not value.is_absolute() or Path(os.path.abspath(value)) != value:
        raise ValueError(label + ' must be an absolute canonical path')
    try:
        if value.resolve(strict=True) != value:
            raise ValueError(label + ' must not contain symlinks')
    except OSError as exc:
        raise ValueError(label + ' is inaccessible') from exc
    return value


def _worker_policy():
    raw_path = os.environ.get('N1_REVIEW_POLICY')
    digest = os.environ.get('N1_REVIEW_POLICY_DIGEST')
    policy_path = _canonical_absolute(raw_path, 'N1_REVIEW_POLICY')
    if type(digest) is not str or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        raise ValueError('N1_REVIEW_POLICY_DIGEST is invalid')
    try:
        info = policy_path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o222:
            raise ValueError('worker policy must be a read-only regular file')
        raw = policy_path.read_bytes()
    except OSError as exc:
        raise ValueError('worker policy is inaccessible') from exc
    if len(raw) > MAX_FILE_BYTES:
        raise ValueError('worker policy byte limit exceeded')
    if not hmac.compare_digest(hashlib.sha256(raw).hexdigest(), digest):
        raise ValueError('worker policy digest does not match')
    try:
        policy = json.loads(raw, object_pairs_hook=_unique_keys)
    except (json.JSONDecodeError, UnicodeError) as exc:
        raise ValueError('worker policy is malformed') from exc
    if type(policy) is not dict or set(policy) != POLICY_KEYS or policy.get('schemaVersion') != 1:
        raise ValueError('worker policy has an invalid shape')
    source = _canonical_absolute(policy.get('sourceRoot'), 'sourceRoot')
    if not source.is_dir():
        raise ValueError('sourceRoot must be a directory')
    inputs = policy.get('allowedInputPaths')
    if type(inputs) is not list or any(type(item) is not str for item in inputs):
        raise ValueError('allowedInputPaths must be a list of paths')
    allowed = {}
    for raw_input in inputs:
        path = _canonical_absolute(raw_input, 'allowedInputPaths entry')
        if path == policy_path or not path.is_file() or path.stat().st_mode & 0o222:
            raise ValueError('allowed input must be a distinct read-only regular file')
        alias = 'inputs/' + path.name
        if alias in allowed:
            raise ValueError('allowed input names must be unique')
        allowed[alias] = path
    return policy_path, source, allowed


def reader_main(argv: list[str]) -> int:
    """Worker script form: reader.py read|search VALUE, with a trusted policy env."""
    try:
        if len(argv) != 2 or argv[0] not in ('read', 'search'):
            raise ValueError('expected read|search VALUE')
        operation, value = argv
        if operation == 'read':
            safe_relative(value)
        policy_path, root, inputs = _worker_policy()
        if operation == 'search':
            result = search_files(root, value, excluded_paths=(policy_path,))
        elif value in inputs:
            target = inputs[value]
            result = read_file(target.parent, target.name)
        else:
            candidate = (root / value).resolve(strict=False)
            if candidate == policy_path:
                raise ValueError('worker policy is not readable through the worker reader')
            result = read_file(root, value)
        print(json.dumps(result))
        return 0
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(reader_main(sys.argv[1:]))
