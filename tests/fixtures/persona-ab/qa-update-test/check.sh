#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
exec bash "$here/../qa_check.sh" "$1" src/price.py "$here/mutant.py"
