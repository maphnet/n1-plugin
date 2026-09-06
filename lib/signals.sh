#!/usr/bin/env bash
# N1 signal block helpers for memory files
#
# Signal blocks are HTML comments so they don't render in markdown viewers:
#
#   <!-- n1:signals
#   blast_radius: low
#   security_relevant: false
#   files_changed: 2
#   -->
#
# Agents emit signals as a single space-separated line:
#   n1:signals key1=val1 key2=val2
#
# The orchestrator bridges these two formats via n1_write_signals.

# n1_read_signal <file> <signal_name>
# Returns the value for the given key from the <!-- n1:signals --> block,
# or empty string if the key or block is not found.
n1_read_signal() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v key="$key" '
        /^<!-- n1:signals$/ { in_block=1; next }
        in_block && /^-->$/ { exit }
        in_block && $0 ~ "^" key ":" {
            sub("^" key ":[[:space:]]*", "")
            gsub(/\r/, "")
            printf "%s", $0
            exit
        }
        /^<!-- n1:signals / && /-->$/ {
            # Inline format: <!-- n1:signals key1=val1 key2=val2 -->
            line = $0
            gsub(/^<!-- n1:signals[[:space:]]+/, "", line)
            gsub(/[[:space:]]*-->$/, "", line)
            n = split(line, pairs, " ")
            for (i = 1; i <= n; i++) {
                eq = index(pairs[i], "=")
                if (eq > 0) {
                    k = substr(pairs[i], 1, eq - 1)
                    v = substr(pairs[i], eq + 1)
                    if (k == key) { printf "%s", v; exit }
                }
            }
        }
    ' "$file"
}

# n1_write_signals <file> <key=value> [<key=value> ...]
# Writes or updates key=value pairs in the <!-- n1:signals --> block.
# If the block already exists, merges: updates matching keys, preserves others,
# appends new keys. If the block does not exist, appends a new one at end of file.
n1_write_signals() {
    local file="$1"
    shift
    [ -f "$file" ] || return 1
    [ $# -eq 0 ] && return 0

    # Write pairs to a temp file so awk can read them without newline-in-variable issues
    local tmpairs
    tmpairs=$(mktemp)
    local pair
    for pair in "$@"; do
        printf '%s\n' "$pair" >> "$tmpairs"
    done

    if grep -q '^<!-- n1:signals$' "$file" 2>/dev/null; then
        # Block exists — update matching keys, preserve others, append new keys
        awk -v pfile="$tmpairs" '
            BEGIN {
                while ((getline line < pfile) > 0) {
                    eq = index(line, "=")
                    if (eq > 0) {
                        k = substr(line, 1, eq - 1)
                        v = substr(line, eq + 1)
                        new_val[k] = v
                        new_key[++nkeys] = k
                    }
                }
                close(pfile)
            }
            /^<!-- n1:signals$/ { in_block=1; print; next }
            in_block && /^-->$/ {
                # Append any new keys not already present in the block
                for (i = 1; i <= nkeys; i++) {
                    if (!written[new_key[i]])
                        print new_key[i] ": " new_val[new_key[i]]
                }
                in_block=0; print; next
            }
            in_block {
                colon = index($0, ":")
                if (colon > 0) {
                    k = substr($0, 1, colon - 1)
                    if (k in new_val) {
                        print k ": " new_val[k]
                        written[k] = 1
                        next
                    }
                }
                print; next
            }
            { print }
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
        # No block — append a new one
        printf '\n<!-- n1:signals\n' >> "$file"
        for pair in "$@"; do
            printf '%s: %s\n' "${pair%%=*}" "${pair#*=}" >> "$file"
        done
        printf -- '-->\n' >> "$file"
    fi

    rm -f "$tmpairs"
}

# n1_eval_signal_gate <memory_dir> <overview_file> <condition_json>
# Evaluates a signal gate condition against memory files.
# Returns 0 (true) if the condition is met, 1 (false) otherwise.
# Requires jq. Falls back to false (no skip) if jq is absent.
#
# Condition format (JSON):
#   { "signal": "analysis.blast_radius", "eq": "low" }
#   { "signal": "brainstorm.files_changed", "fallback": "analysis.files_changed", "lt": 5 }
#   { "frontmatter": "type", "eq": "bug" }
#   { "all": [ <condition>, ... ] }
#   { "any": [ <condition>, ... ] }
n1_eval_signal_gate() {
    local mem_dir="$1" overview="$2" cond="$3"
    command -v jq >/dev/null 2>&1 || return 1

    local has_all has_any
    has_all=$(echo "$cond" | jq -r 'has("all")' 2>/dev/null)
    has_any=$(echo "$cond" | jq -r 'has("any")' 2>/dev/null)

    if [ "$has_all" = "true" ]; then
        local count i sub
        count=$(echo "$cond" | jq '.all | length' 2>/dev/null)
        for ((i=0; i<count; i++)); do
            sub=$(echo "$cond" | jq -c ".all[$i]" 2>/dev/null)
            n1_eval_signal_gate "$mem_dir" "$overview" "$sub" || return 1
        done
        return 0
    fi

    if [ "$has_any" = "true" ]; then
        local count i sub
        count=$(echo "$cond" | jq '.any | length' 2>/dev/null)
        for ((i=0; i<count; i++)); do
            sub=$(echo "$cond" | jq -c ".any[$i]" 2>/dev/null)
            n1_eval_signal_gate "$mem_dir" "$overview" "$sub" && return 0
        done
        return 1
    fi

    # Leaf condition: resolve value
    local actual=""
    local sig fm
    sig=$(echo "$cond" | jq -r '.signal // empty' 2>/dev/null)
    fm=$(echo "$cond" | jq -r '.frontmatter // empty' 2>/dev/null)

    if [ -n "$sig" ]; then
        local file_prefix="${sig%%.*}"
        local key="${sig#*.}"
        actual=$(n1_read_signal "${mem_dir}/${file_prefix}.md" "$key")
        # Fallback: if primary signal is empty, try "fallback" source (e.g. brainstorm → analysis)
        if [ -z "$actual" ]; then
            local fb
            fb=$(echo "$cond" | jq -r '.fallback // empty' 2>/dev/null)
            if [ -n "$fb" ]; then
                local fb_prefix="${fb%%.*}"
                local fb_key="${fb#*.}"
                actual=$(n1_read_signal "${mem_dir}/${fb_prefix}.md" "$fb_key")
            fi
        fi
    elif [ -n "$fm" ]; then
        source "${CLAUDE_PLUGIN_ROOT}/lib/frontmatter.sh" 2>/dev/null || true
        actual=$(n1_read_frontmatter "$overview" "$fm" 2>/dev/null || true)
    fi

    [ -z "$actual" ] && return 1

    # Evaluate operator
    local op val
    for op in eq neq lt gt lte gte; do
        val=$(echo "$cond" | jq -r ".${op} // empty" 2>/dev/null)
        [ -n "$val" ] && break
    done
    [ -z "$val" ] && return 1

    case "$op" in
        eq)  [ "$actual" = "$val" ] ;;
        neq) [ "$actual" != "$val" ] ;;
        lt)  [ "$actual" -lt "$val" ] 2>/dev/null ;;
        gt)  [ "$actual" -gt "$val" ] 2>/dev/null ;;
        lte) [ "$actual" -le "$val" ] 2>/dev/null ;;
        gte) [ "$actual" -ge "$val" ] 2>/dev/null ;;
        *)   return 1 ;;
    esac
}

