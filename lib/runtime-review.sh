#!/usr/bin/env bash
set -euo pipefail
N1_REVIEW_INVOCATION="$PWD"
N1_REVIEW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$N1_REVIEW_ROOT/lib/config.sh"
N1_REVIEW_HOME="$(n1_home)" || true
test -n "$N1_REVIEW_HOME" || { echo 'N1 home is not configured' >&2; exit 2; }
N1_REVIEW_CONFIG="$(n1_config_file)"
case "$N1_REVIEW_HOME" in
    /*) ;;
    *) N1_REVIEW_HOME="$N1_REVIEW_INVOCATION/$N1_REVIEW_HOME" ;;
esac
case "$N1_REVIEW_CONFIG" in
    /*) ;;
    *) N1_REVIEW_CONFIG="$N1_REVIEW_INVOCATION/$N1_REVIEW_CONFIG" ;;
esac
# Keep cwd for conventions, but never import checkout-local Python packages.
python3 -I -c 'import runpy, sys; sys.path.insert(0, sys.argv.pop(1)); runpy.run_module("lib.runtime_review.cli", run_name="__main__")' \
  "$N1_REVIEW_ROOT" --home "$N1_REVIEW_HOME" --config-file "$N1_REVIEW_CONFIG" "$@"
