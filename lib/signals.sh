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
