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
        test_*.py|*_test.py|*.test.*|*.spec.*|*_test.go|*Test.java|*Tests.cs|*_spec.rb|test_*.sh|*_test.sh) return 0 ;;
    esac
    return 1
}

_n1_bc_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s\n' "${s%"${s##*[![:space:]]}"}"; }

# n1_break_check_parse_line <qa.md "Regression test:"/"New test:" line> <name|cmd>
# Contract: "<Kind> test: <name> | `<command>`". name = text before the first "| `"; command = text
# inside that backtick pair; anything after the closing backtick is dropped (stderr warning in cmd mode).
# Never splits on the last pipe (names and commands may contain "|"). No "| `" → legacy split on the
# first "|" with backticks removed (bare commands exist in older qa.md files).
n1_break_check_parse_line() {
    local bt='`' rest="${1#*test:}" name cmd tail="" amb=""
    case "$rest" in
        *"| $bt"*"$bt"*)
            name="${rest%%"| $bt"*}"; cmd="${rest#*"| $bt"}"
            tail="${cmd#*"$bt"}"; cmd="${cmd%%"$bt"*}" ;;
        *"|"*) name="${rest%%|*}"; cmd="${rest#*|}"; cmd="${cmd//"$bt"/}"
            case "$cmd" in *"|"*) amb=1; cmd="" ;; esac ;;
        *) name="$rest"; cmd="" ;;
    esac
    if [ "$2" = cmd ]; then
        [ -z "$amb" ] || echo "break-check: ambiguous legacy line (several '|', no backticked command); no command extracted" >&2
        [ -z "${tail//[[:space:]]/}" ] || echo "break-check: ignoring text after the command: $(_n1_bc_trim "$tail")" >&2
        _n1_bc_trim "$cmd"
    else
        _n1_bc_trim "${name//"$bt"/}"
    fi
}

# n1_break_check_base <branch-point-file> <default-branch> [<repo_dir>]
# Prints the recorded branch-point when it is an ancestor of HEAD; otherwise the merge-base of HEAD
# with origin/<default> (then local <default>), else <default>.
n1_break_check_base() {
    local bp="" def="${2:-main}" dir="${3:-.}" mb=""
    [ -f "$1" ] && bp=$(tr -d '[:space:]' < "$1")
    if [ -n "$bp" ] && git -C "$dir" merge-base --is-ancestor "$bp" HEAD 2>/dev/null; then
        printf '%s\n' "$bp"; return 0
    fi
    mb=$(git -C "$dir" merge-base HEAD "origin/$def" 2>/dev/null || git -C "$dir" merge-base HEAD "$def" 2>/dev/null) || mb=""
    printf '%s\n' "${mb:-$def}"
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
    ( cd "$dir" && timeout -k 30 "${N1_BREAKCHECK_TIMEOUT:-600}" env -u N1_RUN_ID bash -c "$cmd" </dev/null ) >> "$log" 2>&1
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

_n1_bc_has() {  # <newline list> <name> → 0 when the list holds name exactly (parsers already strip runner suffixes)
    [ -n "$2" ] || return 1
    grep -qxF -e "$2" <<< "$1"
}
# _n1_bc_accounted <base_pass> <rev_pass> <failed> <name> → 0 when every baseline test that vanished from the
# reverted run (other than name) has its own FAIL line and at least one FAIL line is unattributed (name's).
_n1_bc_accounted() {
    local n unexplained=0
    while IFS= read -r n; do
        [ -n "$n" ] && [ "$n" != "$4" ] || continue
        _n1_bc_has "$2" "$n" || _n1_bc_has "$3" "$n" || return 1
    done <<< "$1"
    while IFS= read -r n; do
        [ -n "$n" ] && ! _n1_bc_has "$1" "$n" && unexplained=1
    done <<< "$3"
    [ "$unexplained" -eq 1 ]
}

# n1_break_check <base_ref> <test_cmd> <test_name> <log_path> [<repo_dir>]
n1_break_check() {
    local base="$1" cmd="$2" name="$3" log="$4" dir="${5:-.}"
    local dir_abs; dir_abs=$(cd "$dir" && pwd)
    local log_abs; log_abs=$(realpath -m "$log")
    : > "$log"

    if [ -z "${cmd//[[:space:]]/}" ] || [ -z "${name//[[:space:]]/}" ]; then
        _n1_bc_json false inconclusive "empty command or test name" inconclusive "$name" "$log"
        return 2
    fi

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
        _n1_bc_json false no-diff "no non-test files changed since ${base}; nothing to revert" no-diff "$name" "$log"
        return 2
    fi

    echo "=== baseline run (fix present) ===" >> "$log"
    local base_log; base_log=$(mktemp)
    if ! _n1_bc_run "$cmd" "$base_log" "$dir"; then
        cat "$base_log" >> "$log"; rm -f "$base_log"
        _n1_bc_json false inconclusive "baseline run is not green with the fix present" inconclusive "$name" "$log"
        return 0
    fi
    cat "$base_log" >> "$log"
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
    ( cd "$dir" && timeout -k 30 "${N1_BREAKCHECK_TIMEOUT:-600}" env -u N1_RUN_ID bash -c "$cmd" </dev/null ) > "$revert_log" 2>&1 || rc_rev=$?
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

    local failed_names base_pass rev_pass
    failed_names=$(n1_testparse_failed_names "$revert_log")
    base_pass=$(n1_testparse_passed_names "$base_log"); rev_pass=$(n1_testparse_passed_names "$revert_log")
    rm -f "$base_log"

    if [ "$restore_ok" != "true" ]; then
        _n1_bc_json false inconclusive "tree or suite not green after restore; inspect log" inconclusive "$name" "$log"
        rm -f "$revert_log"; return 0
    fi
    if [ "$rc_rev" -eq 124 ] || [ "$rc_rev" -eq 137 ]; then  # 137 = SIGKILL after -k grace
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
    if n1_break_check_is_test_path "$name"; then
        # File-level runner: the parsed failure names are per-check descriptions,
        # not the file-level name itself, so any parsed failure counts as red.
        if [ -n "$failed_names" ]; then
            _n1_bc_json true "" "" red-then-green "$name" "$log"
        else
            _n1_bc_json true "" "" never-red "$name" "$log"
        fi
    elif _n1_bc_has "$failed_names" "$name"; then
        _n1_bc_json true "" "" red-then-green "$name" "$log"
    elif [ "$rc_rev" -ne 0 ] && _n1_bc_has "$base_pass" "$name" && ! _n1_bc_has "$rev_pass" "$name"; then
        # PASS-set rule: the named test passed with the fix and not reverted; its FAIL text may differ
        # from its PASS name. Only runners that print PASS lines reach here.
        if _n1_bc_accounted "$base_pass" "$rev_pass" "$failed_names" "$name"; then
            _n1_bc_json true "" "" red-then-green "$name" "$log"
        else
            _n1_bc_json false inconclusive "cannot establish that the named test ran and failed in the reverted run (aborted?)" inconclusive "$name" "$log"
        fi
    else
        _n1_bc_json true "" "" never-red "$name" "$log"
    fi
    return 0
}
