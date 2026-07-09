#!/usr/bin/env bash
# N1 YAML frontmatter helpers for memory files (overview.md, etc.)

n1_read_frontmatter() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v key="$key" '
        NR==1 && /^---$/ { in_fm=1; next }
        in_fm && /^---$/ { exit }
        in_fm && $0 ~ "^" key ":" {
            sub("^" key ":[[:space:]]*", "")
            gsub(/\r/, "")
            printf "%s", $0
            exit
        }
    ' "$file"
}

n1_write_frontmatter() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || return 1
    head -1 "$file" | grep -q '^---$' || return 1
    awk -v key="$key" -v val="$value" '
        NR==1 && /^---$/ { in_fm=1; print; next }
        in_fm && /^---$/ {
            if (!replaced) print key ": " val
            in_fm=0; print; next
        }
        in_fm && $0 ~ "^" key ":" { print key ": " val; replaced=1; next }
        { print }
    ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

n1_increment_counter() {
    local file="$1" key="$2"
    local current
    current=$(n1_read_frontmatter "$file" "$key")
    current=${current:-0}
    local new_val=$((current + 1))
    n1_write_frontmatter "$file" "$key" "$new_val"
    printf '%s' "$new_val"
}
