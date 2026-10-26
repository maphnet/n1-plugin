#!/usr/bin/env bash
# Shared QA fixture check: qa_check.sh <repo> <src-file> <mutant-file>
# Pass when src/ is unchanged, the test suite passes, and the suite fails once
# <src-file> is replaced by the known-bad <mutant-file>.
set -u
export PYTHONDONTWRITEBYTECODE=1
repo=$1 src=$2 mutant=$3
cd "$repo" || exit 1
git diff --quiet HEAD -- src || { echo "src/ modified"; exit 1; }
python3 -m unittest discover -q >/dev/null 2>&1 || { echo "tests fail"; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R . "$work/r"
rm -rf "$work/r/src/__pycache__"
cp "$mutant" "$work/r/$src"
if (cd "$work/r" && python3 -m unittest discover -q >/dev/null 2>&1); then
    echo "tests miss the mutant"; exit 1
fi
exit 0
