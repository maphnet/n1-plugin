#!/usr/bin/env bash
# Pass when calc.clamp exists and behaves; add is unchanged.
cd "$1" || exit 1
python3 - <<'PY'
from calc import add, clamp
assert add(2, 3) == 5
assert clamp(5, 0, 10) == 5
assert clamp(-1, 0, 10) == 0
assert clamp(11, 0, 10) == 10
try:
    clamp(1, 5, 0)
except ValueError:
    pass
else:
    raise AssertionError("expected ValueError")
PY
