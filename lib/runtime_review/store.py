"""Controller-owned scratch storage with POSIX locking and generation CAS.

The source helper creates inputs/ and source/ during preparation. This module
owns state.json, requests/, results/, inputs/claims, and report.md. No resume or
caller-selected artifact path is exposed.
"""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import stat
from uuid import UUID, uuid4

try:
    import fcntl
except ImportError:  # Unsupported platforms must fail before dispatch.
    fcntl = None

from .reader import MAX_FILE_BYTES, MAX_TOTAL_BYTES, _root_fd
from .report import render_report
from .workflow import ROLES, TERMINAL


def check_platform():
    if fcntl is None or not hasattr(os, "O_NOFOLLOW"):
        raise ValueError("runtime review requires POSIX fcntl locking and no-follow file access")


def _uuid(value):
    try:
        parsed = UUID(value) if type(value) is str else None
    except ValueError as exc:
        raise ValueError("runId must be a canonical random UUID") from exc
    if parsed is None or parsed.version != 4 or str(parsed) != value:
        raise ValueError("runId must be a canonical random UUID")
    return value


def create_run(home: Path) -> Path:
    check_platform()
    home = Path(home).resolve(strict=True)
    fd = _root_fd(home)
    try:
        for name in ("scratch", "reviews"):
            try:
                os.mkdir(name, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        run_id = str(uuid4())
        os.mkdir(run_id, mode=0o700, dir_fd=fd)
        child = os.open(run_id, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        os.close(fd)
        fd = child
        for name in ("requests", "results"):
            os.mkdir(name, mode=0o700, dir_fd=fd)
        os.fsync(fd)
        return home / "scratch" / "reviews" / run_id
    finally:
        os.close(fd)


def resolve_run(home: Path, run_id: str) -> Path:
    _uuid(run_id)
    run = Path(home).resolve(strict=True) / "scratch" / "reviews" / run_id
    try:
        fd = _root_fd(run)
        os.close(fd)
    except OSError as exc:
        raise ValueError("runId is unknown or inaccessible under this home") from exc
    return run


def _run_fd(run_dir):
    run_dir = Path(run_dir)
    _uuid(run_dir.name)
    if run_dir.parent.name != "reviews" or run_dir.parent.parent.name != "scratch":
        raise ValueError("run directory must be controller-owned scratch/reviews/<uuid>")
    return _root_fd(run_dir)


@contextmanager
def _locked(run_dir):
    check_platform()
    fd = _run_fd(run_dir)
    lock_fd = None
    try:
        lock_fd = os.open(".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=fd)
        if not stat.S_ISREG(os.fstat(lock_fd).st_mode):
            raise ValueError("run lock must be a regular file")
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        yield fd
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(fd)


def _read_state(fd):
    try:
        file_fd = os.open("state.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    except FileNotFoundError:
        return None
    with os.fdopen(file_fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_TOTAL_BYTES:
            raise ValueError("state.json must be a bounded regular file")
        data = handle.read(MAX_TOTAL_BYTES + 1)
    if len(data) > MAX_TOTAL_BYTES:
        raise ValueError("state.json byte limit exceeded")
    state = json.loads(data)
    if type(state) is not dict:
        raise ValueError("state.json must be an object")
    return state


def load_state(run_dir: Path) -> dict:
    with _locked(run_dir) as fd:
        state = _read_state(fd)
        if state is None:
            raise ValueError("run has no state; preparation is incomplete and cannot resume")
        return state


def _atomic_write(fd, name, text):
    temporary = ".tmp-" + str(uuid4())
    file_fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600, dir_fd=fd)
    try:
        with os.fdopen(file_fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, name, src_dir_fd=fd, dst_dir_fd=fd)
        os.fsync(fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=fd)
        except FileNotFoundError:
            pass


def save_state(run_dir: Path, state: dict, expected_generation: int) -> None:
    """Persist exactly one accepted generation, or reject a stale writer."""
    if type(expected_generation) is not int or expected_generation < 0:
        raise ValueError("expected_generation must be a nonnegative integer")
    if type(state) is not dict or type(state.get("generation")) is not int:
        raise ValueError("state.generation must be an integer")
    if state["generation"] != expected_generation + 1:
        raise ValueError("state.generation must advance by exactly one")
    if type(state.get("status")) is not str or state["status"] not in TERMINAL | {"pending", "reviewing", "verifying"}:
        raise ValueError("state.status must be known")
    serialized = json.dumps(state, ensure_ascii=False, allow_nan=False, indent=2) + "\n"
    with _locked(run_dir) as fd:
        previous = _read_state(fd)
        actual = 0 if previous is None else previous.get("generation")
        if actual != expected_generation:
            raise ValueError("state generation changed; stale writer rejected")
        if previous is not None and previous.get("status") in TERMINAL and state["status"] != previous["status"]:
            raise ValueError("terminal run status cannot change")
        if "eventIds" in state or (previous is not None and "eventIds" in previous):
            old_ids = [] if previous is None else previous.get("eventIds", [])
            ids = state.get("eventIds")
            if (type(ids) is not list or any(type(item) is not str or not item for item in ids)
                    or len(set(ids)) != len(ids) or ids[:-1] != old_ids):
                raise ValueError("eventIds must append exactly one unique event without rewriting history")
        if "runId" in state and state["runId"] != Path(run_dir).name:
            raise ValueError("state.runId must match run directory")
        if "workers" in state:
            _write_artifacts(fd, state)
        _atomic_write(fd, "state.json", serialized)


def _write_artifacts(fd, state):
    # Artifact names are selected from controller-owned roles, never worker paths.
    for directory, field in (("requests", "request"), ("results", "result")):
        child = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            for role in ROLES:
                value = state["workers"][role][field]
                if value is not None:
                    _atomic_write(child, role + ".json", json.dumps(value, ensure_ascii=False, allow_nan=False) + "\n")
        finally:
            os.close(child)
    if state["workers"]["review-verifier"]["status"] != "pending":
        child = os.open("inputs", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            _atomic_write(child, "claims", json.dumps(state["claims"], ensure_ascii=False, allow_nan=False) + "\n")
            os.chmod("claims", 0o400, dir_fd=child, follow_symlinks=False)
        finally:
            os.close(child)
    _atomic_write(fd, "report.md", render_report(state))


def save_raw_result(run_dir: Path, request_id: str, raw_text: str) -> None:
    """Retain adapter-captured worker text separately from a validated envelope."""
    if type(raw_text) is not str or len(raw_text.encode("utf-8")) > MAX_FILE_BYTES:
        raise ValueError("rawText must be a bounded string")
    with _locked(run_dir) as fd:
        state = _read_state(fd)
        role = next((role for role in ROLES if state is not None
                     and state["workers"][role]["request"]["requestId"] == request_id
                     and state["workers"][role]["result"] is not None), None)
        if role is None:
            raise ValueError("rawText requires an accepted result for this run")
        child = os.open("results", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        try:
            _atomic_write(child, role + ".raw.txt", raw_text)
        finally:
            os.close(child)


def local_report(run_dir: Path) -> tuple[dict, str]:
    with _locked(run_dir) as fd:
        state = _read_state(fd)
        if state is None:
            raise ValueError("run has no state; preparation is incomplete and cannot resume")
        report = render_report(state)
        _atomic_write(fd, "report.md", report)
        return state, report
