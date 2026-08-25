#!/usr/bin/env bash
# N1 cross-pass finding fingerprint helpers.
# Persistence format: JSONL in $N1_HOME/memory/<ID>/fingerprints.jsonl
# Each line: {"fp":"<hex>","id":"<CX-1>","severity":"High","status":"active","cycle":1,"ts":"..."}

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
    # Exit 0 if converging (current cycle count < previous cycle count), exit 1 if not.
    local jsonl_file="$1" current_cycle="$2"
    [ -f "$jsonl_file" ] || return 0  # No history — converging by default
    local prev_cycle=$(( current_cycle - 1 ))
    [ "$prev_cycle" -lt 1 ] && return 0  # First cycle, no prior to compare against
    local cur_count prev_count
    cur_count=$(n1_fingerprint_blocking_count_for_cycle "$jsonl_file" "$current_cycle")
    prev_count=$(n1_fingerprint_blocking_count_for_cycle "$jsonl_file" "$prev_cycle")
    [ "$cur_count" -lt "$prev_count" ] 2>/dev/null && return 0
    return 1
}
