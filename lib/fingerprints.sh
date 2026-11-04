#!/usr/bin/env bash
# N1 cross-pass finding fingerprint helpers.
# Persistence format: JSONL in $N1_HOME/memory/<ID>/fingerprints.jsonl
# Each line: {"fp":"<hex>","id":"<CR-1>","severity":"High","status":"active","cycle":1,"ts":"..."}

_n1_portable_hash() {
    # Portable MD5 hash: tries md5sum (Linux), md5 -r (macOS), sha256sum as last resort
    local input="$1"
    if command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$input" | md5sum | cut -d' ' -f1
    elif command -v md5 >/dev/null 2>&1; then
        printf '%s' "$input" | md5 -r | cut -d' ' -f1
    else
        printf '%s' "$input" | sha256sum | cut -d' ' -f1
    fi
}

n1_fingerprint_finding() {
    # Usage: n1_fingerprint_finding <file_path> <title>
    # Produces a stable fingerprint from repository-relative path + normalized title
    local file="$1" title="$2"
    # Normalize path: lowercase, strip leading ./
    local norm_path
    norm_path=$(printf '%s' "$file" | sed 's|^\./||' | tr '[:upper:]' '[:lower:]')
    # Normalize title: lowercase, strip whitespace runs, trim
    local norm_title
    norm_title=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
    _n1_portable_hash "${norm_path}:${norm_title}"
}

n1_fingerprint_append() {
    # Usage: n1_fingerprint_append <jsonl_file> <fingerprint> <finding_id> <severity> <status> [cycle]
    local jsonl_file="$1" fp="$2" fid="$3" severity="$4" status="$5" cycle="${6:-1}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$jsonl_file")"
    printf '{"fp":"%s","id":"%s","severity":"%s","status":"%s","cycle":%s,"ts":"%s"}\n' \
        "$fp" "$fid" "$severity" "$status" "$cycle" "$ts" >> "$jsonl_file"
}

n1_fingerprint_record() {
    # Usage: n1_fingerprint_record <jsonl_file> <tsv_file> [cycle]
    # TSV line: <id>\t<severity>\t<file>\t<title> (title = rest of line, may contain tabs).
    # Reviewer text is read as data from the file, never placed in shell command text (N1-136).
    # Empty fields are kept (an empty <file> hashes with an empty path); id and severity are validated.
    # Returns non-zero if any row was skipped or failed to append; the TSV is then renamed to
    # <tsv>.rejected for inspection, and removed on full success, so it is never re-read under a later cycle.
    # A trailing CR in the title is absorbed by n1_fingerprint_finding's whitespace normalization.
    local jsonl_file="$1" tsv="$2" cycle="${3:-1}" line rest id sev file title rc=0 tab=$'\t'
    [ -r "$tsv" ] || { echo "n1_fingerprint_record: cannot read $tsv" >&2; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "${line//[$'\r ']/}" ] || continue
        case "$line" in *"$tab"*"$tab"*"$tab"*) ;; *) echo "n1_fingerprint_record: skipping malformed line" >&2; rc=1; continue ;; esac
        id=${line%%"$tab"*}; rest=${line#*"$tab"}
        sev=${rest%%"$tab"*}; rest=${rest#*"$tab"}
        file=${rest%%"$tab"*}; title=${rest#*"$tab"}
        [[ "$id" =~ ^[A-Z]+-[0-9]+$ && "$sev" =~ ^(Critical|High|Medium|Low)$ && -n "${title//[$'\r ']/}" ]] \
            || { echo "n1_fingerprint_record: skipping invalid line for '${id:0:20}'" >&2; rc=1; continue; }
        n1_fingerprint_append "$jsonl_file" "$(n1_fingerprint_finding "$file" "$title")" "$id" "$sev" active "$cycle" || rc=1
    done < "$tsv"
    if [ "$rc" -eq 0 ]; then rm -f "$tsv" || rc=1; else mv -f "$tsv" "$tsv.rejected" || rc=1; fi
    return "$rc"
}

n1_fingerprint_known() {
    # Usage: n1_fingerprint_known <jsonl_file> <fingerprint>
    # Exit 0 if fingerprint exists, 1 otherwise
    local jsonl_file="$1" fp="$2"
    [ -f "$jsonl_file" ] || return 1
    grep -q "\"fp\":\"${fp}\"" "$jsonl_file" 2>/dev/null
}

n1_fingerprint_blocking_count() {
    # Usage: n1_fingerprint_blocking_count <jsonl_file>
    # Prints count of distinct active Critical/High fingerprints
    local jsonl_file="$1"
    [ -f "$jsonl_file" ] || { printf '0'; return; }
    # Get the latest status for each fingerprint, count those that are active + Critical/High
    if command -v jq >/dev/null 2>&1; then
        # jq: group by fp, take last entry per fp, filter active + Critical/High
        jq -s '
            group_by(.fp) | map(last) |
            map(select(.status == "active" and (.severity == "Critical" or .severity == "High"))) |
            length
        ' "$jsonl_file" 2>/dev/null || printf '0'
    else
        # Fallback: grep for active Critical/High, extract unique fps
        grep '"status":"active"' "$jsonl_file" 2>/dev/null \
            | grep -E '"severity":"(Critical|High)"' \
            | grep -o '"fp":"[^"]*"' | sort -u | wc -l | tr -d ' '
    fi
}

n1_fingerprint_blocking_count_for_cycle() {
    # Usage: n1_fingerprint_blocking_count_for_cycle <jsonl_file> <cycle>
    # Prints count of distinct active Critical/High fingerprints for the given cycle number
    local jsonl_file="$1" cycle="$2"
    [ -f "$jsonl_file" ] || { printf '0'; return; }
    if command -v jq >/dev/null 2>&1; then
        jq -s --argjson c "$cycle" '
            map(select(.cycle == $c)) |
            group_by(.fp) | map(last) |
            map(select(.status == "active" and (.severity == "Critical" or .severity == "High"))) |
            length
        ' "$jsonl_file" 2>/dev/null || printf '0'
    else
        # Fallback: filter by cycle field, grep for active Critical/High, count unique fps
        grep "\"cycle\":${cycle}" "$jsonl_file" 2>/dev/null \
            | grep '"status":"active"' \
            | grep -E '"severity":"(Critical|High)"' \
            | grep -o '"fp":"[^"]*"' | sort -u | wc -l | tr -d ' '
    fi
}

n1_fingerprint_check_convergence() {
    # Usage: n1_fingerprint_check_convergence <jsonl_file> <current_cycle>
    # Compares blocking count for cycle N vs cycle N-1.
    # Cycles are 0-based: pass 1 = bucket 0, re-review N = bucket N.
    # Exit 0 if converging (current count < previous count, or current count is 0), exit 1 if not.
    local jsonl_file="$1" current_cycle="$2"
    [ -f "$jsonl_file" ] || return 0  # No history — converging by default
    local prev_cycle=$(( current_cycle - 1 ))
    [ "$prev_cycle" -lt 0 ] && return 0  # Cycle 0 is the first pass, no prior to compare against
    local cur_count prev_count
    cur_count=$(n1_fingerprint_blocking_count_for_cycle "$jsonl_file" "$current_cycle")
    [ "$cur_count" -eq 0 ] 2>/dev/null && return 0  # No blocking fingerprints is never non-converging
    prev_count=$(n1_fingerprint_blocking_count_for_cycle "$jsonl_file" "$prev_cycle")
    [ "$cur_count" -lt "$prev_count" ] 2>/dev/null && return 0
    return 1
}

_n1_fp_eligible_rows() {
    # Usage: _n1_fp_eligible_rows <jsonl_file> <cycle>
    # Prints active rows of bucket <cycle> that can earn the one extra review round (N1-345 D17):
    # Critical/High, or Medium [SEC-N]. Recorded Low never qualifies. "cycle":N, is anchored (ts follows).
    [ -r "$1" ] && [[ "$2" =~ ^[0-9]+$ ]] || return 0
    grep "\"cycle\":$2," "$1" 2>/dev/null | grep '"status":"active"' \
        | grep -E '"id":"[A-Z]+-[0-9]+","severity":"(Critical|High)"|"id":"SEC-[0-9]+","severity":"Medium"'
    return 0
}

n1_fingerprint_recurred() {
    # Usage: n1_fingerprint_recurred <jsonl_file> <cycle>
    # Exit 0 when an eligible fingerprint of bucket <cycle> is also in bucket <cycle>-1 (N1-345 D2/D16:
    # the finding oscillates, so no extra round). Exit 1 otherwise, including bad input.
    local jsonl_file="$1" cycle="$2" prev fp
    [[ "$cycle" =~ ^[0-9]+$ ]] && [ "$cycle" -ge 1 ] && [ -r "$jsonl_file" ] || return 1
    prev=$(grep "\"cycle\":$((cycle - 1))," "$jsonl_file" 2>/dev/null)
    while IFS= read -r fp; do
        [ -n "$fp" ] && [[ "$prev" == *"$fp"* ]] && return 0
    done < <(_n1_fp_eligible_rows "$jsonl_file" "$cycle" | grep -o '"fp":"[^"]*"')
    return 1
}

n1_fingerprint_filter_oos() {
    # Usage: n1_fingerprint_filter_oos <jsonl> <cycle> <fix-changed-files> <review-prev.md> <index-file>
    # Extra review round only (N1-345 D20). Removes from <index-file> each Index line
    # `- [ID] <severity> <file>:<line> — <title>` (any severity/prefix) that is new and out of the fix's reach:
    # no <review-prev.md> Index line with the same ID and file, fingerprint (file before the last ':', title) absent from bucket <cycle>-1,
    # and file (./ stripped, case-insensitive) absent from <fix-changed-files>. Prints the removed lines verbatim.
    # Fail-safe: a missing/empty input, cycle < 1, an unparsable line, a location that is not one repo-relative
    # path (absolute, a/ b/ prefix, list) or any [SEC-N] finding keeps the finding in the loop.
    # Reviewer text is read from files as data, never placed in shell command text (N1-136).
    local jsonl="$1" cycle="$2" fixf="$3" prev="$4" idx="$5" sep=' — '
    local line id sev rest loc file title fp norm bucket fixl tmp pl out=""
    [[ "$cycle" =~ ^[0-9]+$ ]] && [ "$cycle" -ge 1 ] && [ -s "$fixf" ] && [ -r "$prev" ] && [ -r "$jsonl" ] && [ -r "$idx" ] || return 0
    bucket=$(grep "\"cycle\":$((cycle - 1))," "$jsonl" 2>/dev/null)
    fixl=$(sed 's|^\./||' "$fixf" | tr '[:upper:]' '[:lower:]')
    tmp=$(mktemp "${idx}.XXXXXX") || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^-\ \[([A-Z]+-[0-9]+)\]\ ([^ ]+)\ (.+)$ ]]; then
            id=${BASH_REMATCH[1]}; sev=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
            if [[ "$rest" == *"$sep"* ]]; then
                loc=${rest%%"$sep"*}; title=${rest#*"$sep"}
                if [[ "$loc" == *:* ]] && [[ ! "$id" =~ ^SEC-[0-9]+$ ]]; then
                    file=${loc%:*}
                    # single repo-relative path only (SEC-2); [SEC-N] is never filtered (SEC-1)
                    # open in prev = same id AND same file on one Index line (CR-1: ids restart per run)
                    pl=$(grep -F -- "- [$id] " "$prev")
                    if [[ "$file" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ ]] && [[ ! "$file" =~ ^[ab]/ ]] \
                        && [ -n "${title//[[:space:]]/}" ] && [[ "$pl" != *" $file:"* ]]; then
                        fp=$(n1_fingerprint_finding "$file" "$title")
                        norm=$(printf '%s' "$file" | sed 's|^\./||' | tr '[:upper:]' '[:lower:]')
                        if [[ "$bucket" != *"\"fp\":\"$fp\""* ]] && ! grep -qxF -- "$norm" <<< "$fixl"; then
                            out+="$line"$'\n'; continue
                        fi
                    fi
                fi
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$idx"
    if mv -f "$tmp" "$idx"; then printf '%s' "$out"; else rm -f "$tmp"; return 1; fi
}
