#!/usr/bin/env bash
# N1 YAML frontmatter helpers for memory files (overview.md, etc.)

n1_read_frontmatter() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v key="$key" '
        NR==1 && /^---\r?$/ { in_fm=1; next }
        in_fm && /^---\r?$/ { exit }
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
    head -1 "$file" | awk '/^---\r?$/ { found=1 } END { exit !found }' || return 1
    # Unique temp per call (NP-206): concurrent writers never share a temp inode.
    local tmp; tmp=$(mktemp "${file}.XXXXXX")
    awk -v key="$key" -v val="$value" '
        NR==1 && /^---\r?$/ { in_fm=1; print; next }
        in_fm && /^---\r?$/ {
            if (!replaced) print key ": " val
            in_fm=0; print; next
        }
        in_fm && $0 ~ "^" key ":" { print key ": " val; replaced=1; next }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
}

n1_increment_counter() {
    local file="$1" key="$2"
    local current
    current=$(n1_read_frontmatter "$file" "$key")
    current=${current:-0}
    [[ "$current" =~ ^[0-9]+$ ]] || { echo "ERROR: non-numeric $key in $file" >&2; return 1; }
    local new_val=$((current + 1))
    n1_write_frontmatter "$file" "$key" "$new_val"
    printf '%s' "$new_val"
}

# N1-277: drop the awaiting-merge marker once the PR is merged (n1-finish Step 6, n1_clean_ticket, clean-pending.sh).
# Removes the frontmatter `awaiting:` key and, in each `## Pending` section, the marker lines pr.md writes (awaiting,
# pr, branch, last_checked, created; pr_url only when a pr_url line exists outside Pending, e.g. ## Finish or
# frontmatter). A section with other lines left is renamed `## Pending notes` (no data lost); an emptied one is
# deleted. Two awk passes over the file: pass 1 finds pr_url copies and leftovers, pass 2 writes.
# Idempotent; missing file: rc 0; write failure: rc 1, file unchanged.
n1_pending_clear() {
    local file="$1" tmp
    [ -f "$file" ] || return 0
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    awk '
        FNR == 1 { pass++; fm = 0; sec = 0; k = 0 }
        FNR == 1 && /^---\r?$/ { fm = 1; if (pass == 2) print; next }
        fm && /^---\r?$/ { fm = 0; if (pass == 2) print; next }
        fm { if (/^pr_url:/) url = 1; if (pass == 2 && !/^awaiting:/) print; next }
        /^## / { sec = /^## Pending\r?$/; if (sec) k++ }
        pass == 1 {
            if (!sec && /^pr_url:/) url = 1
            else if (sec && /^pr_url:/) urls[k] = 1
            else if (sec && !/^## / && !/^(awaiting|pr|branch|last_checked|created):/ && !/^[[:space:]]*\r?$/) left[k] = 1
            next
        }
        sec && /^## / { keep = left[k] || (urls[k] && !url); if (keep) print "## Pending notes"; next }
        sec && (/^(awaiting|pr|branch|last_checked|created):/ || (/^pr_url:/ && url)) { next }
        sec && !keep { next }
        { print }
    ' "$file" "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# N1-528: upsert "- **<Key>:** <value>" in overview ## Finish (n1-finish covered close). Drops any existing line
# for that key inside ## Finish and prints the new one right after the heading; no ## Finish -> appends a minimal
# one. Same awk shape as _n1_clean_record. Missing file or write failure: rc 1, file unchanged.
n1_finish_line_set() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || return 1
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    K="- **$key:**" L="- **$key:** $value" awk '
        /^## / { s = /^## Finish\r?$/ }
        s && index($0, ENVIRON["K"]) == 1 { next }
        { print }
        /^## Finish\r?$/ && !d { print ENVIRON["L"]; d = 1 }
        END { if (!d) { print ""; print "## Finish"; print ENVIRON["L"] } }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# N1-277: finish exited without a merge (timeout paths): keep the marker, set step: finish and refresh last_checked
# wherever it is (frontmatter or ## Pending). No last_checked line: only step is set (no key is invented).
n1_pending_touch() {
    local file="$1"
    [ -f "$file" ] || return 0
    n1_write_frontmatter "$file" step finish || true
    sed -i "s/^last_checked:.*/last_checked: $(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$file"
}
