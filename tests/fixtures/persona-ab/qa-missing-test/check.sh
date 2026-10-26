#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
exec bash "$here/../qa_check.sh" "$1" src/strutil.py "$here/mutant.py"
