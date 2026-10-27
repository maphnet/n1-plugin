#!/usr/bin/env bash
# Pass when word_count counts whitespace-separated words.
cd "$1" || exit 1
python3 - <<'PY'
from text import word_count
assert word_count("") == 0
assert word_count("one") == 1
assert word_count("a  b") == 2
assert word_count(" a\tb\nc ") == 3
PY
