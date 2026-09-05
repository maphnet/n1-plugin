#!/usr/bin/env bash
# lib/breakcheck.sh — verify a test can fail: revert non-test files to base, run, expect the named test red; restore, expect green.
# Never uses git stash (shared stash stack). Prints one JSON envelope line.

_N1_BC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_N1_BC_DIR}/testparse.sh"
source "${_N1_BC_DIR}/treestate.sh"

# n1_break_check_is_test_path <path> → 0 when the path is a test file by common conventions
n1_break_check_is_test_path() {
    local p="$1"
    case "$p" in
        tests/*|test/*|*/tests/*|*/test/*|__tests__/*|*/__tests__/*|spec/*|*/spec/*) return 0 ;;
    esac
    local b; b=$(basename "$p")
    case "$b" in
        test_*.py|*_test.py|*.test.*|*.spec.*|*_test.go|*Test.java|*Tests.cs|*_spec.rb) return 0 ;;
    esac
    return 1
}

_n1_bc_json() {  # success error_kind error_msg verdict named_test log
    local kind_json="null"
    if [ -n "$2" ]; then
        kind_json=$(jq -cn --arg k "$2" --arg m "$3" '{kind:$k,message:$m}')
    fi
    jq -cn --argjson s "$1" --argjson e "$kind_json" --arg v "$4" --arg n "$5" --arg l "$6" \
        '{success:$s,error:$e,verdict:$v,named_test:$n,log:$l}'
}

_n1_bc_run() {  # cmd log repo_dir → appends output to log, returns runner exit code
    local cmd="$1" log="$2" dir="$3"
    ( cd "$dir" && timeout "${N1_BREAKCHECK_TIMEOUT:-600}" bash -c "$cmd" </dev/null ) >> "$log" 2>&1
}

# _n1_bc_exclude_log <log_abs> <repo_dir_abs>
# If the log file lives inside the repo working tree, add its relative path to
# .git/info/exclude so that git-status never reports it as untracked.
_n1_bc_exclude_log() {
    local log_abs="$1" repo_abs="$2"
    local rel
    rel=$(realpath --relative-to="$repo_abs" "$log_abs" 2>/dev/null) || return 0
    # rel starts with ".." → log is outside the repo, nothing to do
    case "$rel" in ../*|..) return 0 ;; esac
    local exclude="$repo_abs/.git/info/exclude"
    grep -qxF "$rel" "$exclude" 2>/dev/null || echo "$rel" >> "$exclude"
}

# n1_break_check <base_ref> <test_cmd> <test_name> <log_path> [<repo_dir>]
n1_break_check() {
    local base="$1" cmd="$2" name="$3" log="$4" dir="${5:-.}"
    local dir_abs; dir_abs=$(cd "$dir" && pwd)
    local log_abs; log_abs=$(realpath -m "$log")
    : > "$log"

    # Keep the log file invisible to git-status so tree-clean checks remain accurate.
    _n1_bc_exclude_log "$log_abs" "$dir_abs"

    if ! n1_tree_is_clean "$dir"; then
        _n1_bc_json false dirty-tree "working tree has uncommitted changes; break-check needs a clean tree" inconclusive "$name" "$log"
        return 2
    fi

    local nontest
    nontest=$(git -C "$dir" diff --name-only "${base}...HEAD" 2>/dev/null | while IFS= read -r f; do
        n1_break_check_is_test_path "$f" || printf '%s\n' "$f"
    done)
    if [ -z "$nontest" ]; then
        _n1_bc_json false no-diff "no non-test files changed since ${base}; nothing to revert" inconclusive "$name" "$log"
        return 2
    fi

    echo "=== baseline run (fix present) ===" >> "$log"
    if ! _n1_bc_run "$cmd" "$log" "$dir"; then
        _n1_bc_json false inconclusive "baseline run is not green with the fix present" inconclusive "$name" "$log"
        return 0
    fi
    # Clean build artefacts produced by the baseline run (e.g. __pycache__).
    git -C "$dir" clean -q -fd 2>/dev/null || true

    echo "=== reverted run (non-test files at ${base}) ===" >> "$log"
    local revert_log; revert_log=$(mktemp)
    # Files that did not exist at base are deleted for the reverted run; others are checked out from base.
    local f
    while IFS= read -r f; do
        if git -C "$dir" cat-file -e "${base}:${f}" 2>/dev/null; then
            git -C "$dir" checkout -q "$base" -- "$f"
        else
            rm -f "$dir/$f"
        fi
    done <<< "$nontest"
    local rc_rev=0
    ( cd "$dir" && timeout "${N1_BREAKCHECK_TIMEOUT:-600}" bash -c "$cmd" </dev/null ) > "$revert_log" 2>&1 || rc_rev=$?
    cat "$revert_log" >> "$log"

    echo "=== restore ===" >> "$log"
    git -C "$dir" checkout -q HEAD -- . 2>>"$log"
    # Remove all untracked build artefacts left by the reverted run before checking health.
    git -C "$dir" clean -q -fd --exclude "$(basename "$log_abs")" 2>>"$log" || true
    echo "=== post-restore run ===" >> "$log"
    local restore_ok=true
    _n1_bc_run "$cmd" "$log" "$dir" || restore_ok=false
    # Clean artefacts produced by the post-restore run; keep the log file (excluded above).
    git -C "$dir" clean -q -fd --exclude "$(basename "$log_abs")" 2>>"$log" || true
    n1_tree_is_clean "$dir" || restore_ok=false

    local failed_names
    failed_names=$(n1_testparse_failed_names "$revert_log")

    if [ "$restore_ok" != "true" ]; then
        _n1_bc_json false inconclusive "tree or suite not green after restore; inspect log" inconclusive "$name" "$log"
        rm -f "$revert_log"; return 0
    fi
    if [ "$rc_rev" -eq 124 ]; then
        _n1_bc_json false timeout "reverted run exceeded timeout" inconclusive "$name" "$log"
        rm -f "$revert_log"; return 0
    fi
    if [ "$rc_rev" -ne 0 ] && [ -z "$failed_names" ]; then
        # Non-zero exit with no recognizable failing test: build/import error or unknown runner output.
        _n1_bc_json false inconclusive "reverted run failed without a parseable failing test (build or import error?)" inconclusive "$name" "$log"
        rm -f "$revert_log"; return 0
    fi
    if n1_testparse_zero_tests "$revert_log"; then
        _n1_bc_json false inconclusive "reverted run executed zero tests" inconclusive "$name" "$log"
        rm -f "$revert_log"; return 0
    fi
    rm -f "$revert_log"
    if printf '%s\n' "$failed_names" | grep -qxF -- "$name"; then
        _n1_bc_json true "" "" red-then-green "$name" "$log"
    else
        _n1_bc_json true "" "" never-red "$name" "$log"
    fi
    return 0
}
