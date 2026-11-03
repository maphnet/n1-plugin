#!/usr/bin/env python3
"""Test-only policy server for tests/test_hooks.sh (N1-321).

Loads hooks/enforce-agent-policy.py once and answers one request per case. A request on stdin is
NUL-terminated fields: KEY=VALUE ... then "--" then the Bash command. For each request os.environ is
reset to the startup environment minus N1_QUEUE_RUN_ID / N1_HEADLESS (what `env -u` did in the wrapper
call), the KEY=VALUE overrides are applied, and the hook module's own main() runs on the same Bash
PreToolUse payload policy_rc built. The deny chain is never re-implemented here. The exit code is
written as one line to stdout. A field "@KEY=VALUE" sets payload[KEY] and "@-KEY" deletes it (payload variants).
"""
import contextlib
import importlib.util
import io
import json
import os
import sys

policy_py, config_file, plugin_root, payload_cwd = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("eap", policy_py)
eap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eap)
BASE = {k: v for k, v in os.environ.items() if k not in ("N1_QUEUE_RUN_ID", "N1_HEADLESS")}


def fields():
    buf = b""
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            return
        buf += chunk
        *done, buf = buf.split(b"\0")
        for f in done:
            yield f.decode("utf-8", "surrogateescape")


def run(env, pl, cmd):
    os.environ.clear()
    os.environ.update(BASE)
    os.environ.update(env)
    # lru caches (e.g. _current_branch) must not outlive a case: the test changes git state between cases
    for obj in list(vars(eap).values()):
        if callable(getattr(obj, "cache_clear", None)):
            obj.cache_clear()
    payload = {"session_id": "s", "cwd": payload_cwd, "hook_event_name": "PreToolUse",
               "tool_name": "Bash", "tool_input": {"command": cmd}}
    for k, v in pl.items():
        if v is None:
            payload.pop(k, None)
        else:
            payload[k] = v
    sys.argv = ["enforce-agent-policy.py", config_file, plugin_root]
    sys.stdin = io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        try:
            return eap.main()
        except SystemExit as e:
            return e.code if isinstance(e.code, int) else 1
        except Exception:  # rc 1 matches no table's expectation, so the assertion fails loudly
            return 1


it = fields()
for f in it:
    env, pl = {}, {}
    while f != "--":
        k, _, v = f.partition("=")
        if k.startswith("@-"):
            pl[k[2:]] = None
        elif k.startswith("@"):
            pl[k[1:]] = v
        else:
            env[k] = v
        f = next(it)
    sys.stdout.write(f"{run(env, pl, next(it))}\n")
    sys.stdout.flush()
