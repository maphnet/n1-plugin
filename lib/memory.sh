#!/usr/bin/env bash
# N1 memory compaction helpers

# n1_compact_memory <memory_file> <sections_to_keep>
# Archives the full file and replaces it with a compacted version.
#
# 1. If <file>.full.md already exists, skip (never compact twice)
# 2. Copy <file> → <file>.full.md (archive)
# 3. Extract frontmatter (if any) and <!-- n1:signals --> block verbatim
# 4. Extract sections matching the keep-list (markdown ## headings)
# 5. Overwrite <file> with: frontmatter + kept sections + signals block
#
# sections_to_keep: comma-separated list of heading patterns (case-insensitive partial match)
# Example: "summary,conclusions,key decisions,acceptance criteria"
n1_compact_memory() {
    local file="$1" keep_list="$2"

    # 1. Skip if already compacted
    [ -f "${file}.full.md" ] && return 0

    # 2. File must exist
    [ -f "$file" ] || return 1

    # 3. Archive full content
    cp "$file" "${file}.full.md"

    # Write keep patterns to a temp file (one per line, lowercase, trimmed)
    local tmpkeep
    tmpkeep=$(mktemp)
    printf '%s\n' "$keep_list" | tr ',' '\n' | \
        awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); if ($0 != "") print tolower($0) }' \
        > "$tmpkeep"

    # Single-pass awk:
    #   - Frontmatter (---...---) is passed through verbatim
    #   - Signals block (<!-- n1:signals ... -->) is collected and appended at the end
    #   - Level-2 and level-3 headings (## / ###) are independent section boundaries;
    #     each is evaluated against keep patterns regardless of nesting.
    #     Level-4+ headings (####...) inherit the keep status of their nearest ##/### ancestor.
    awk -v kfile="$tmpkeep" '
    BEGIN {
        while ((getline line < kfile) > 0) {
            patterns[++np] = line
        }
        close(kfile)
        in_fm        = 0
        in_signals   = 0
        cur_keep     = 0
        cur_outer_lv = 0
        out_fm       = ""
        out_body     = ""
        out_sig      = ""
    }

    function hlevel(s,    i) {
        i = 0
        while (i < length(s) && substr(s, i + 1, 1) == "#") i++
        return i
    }

    function htext(s,    t) {
        t = s
        sub(/^#+[[:space:]]*/, "", t)
        return t
    }

    function matches(h,    i, hl) {
        hl = tolower(h)
        for (i = 1; i <= np; i++) {
            if (index(hl, patterns[i]) > 0) return 1
        }
        return 0
    }

    NR == 1 && /^---$/ { in_fm = 1; out_fm = out_fm $0 "\n"; next }
    in_fm && /^---$/   { in_fm = 0; out_fm = out_fm $0 "\n"; next }
    in_fm              { out_fm = out_fm $0 "\n"; next }

    /^<!-- n1:signals/ { in_signals = 1; out_sig = out_sig $0 "\n"; next }
    /^<!-- \/n1:signals/ { out_sig = out_sig $0 "\n"; in_signals = 0; next }
    in_signals {
        out_sig = out_sig $0 "\n"
        if (/^-->$/) in_signals = 0
        next
    }

    /^#{2,}[[:space:]]/ {
        lv = hlevel($0)
        ht = htext($0)
        if (lv <= 3) {
            cur_outer_lv = lv
            cur_keep     = matches(ht)
        } else if (cur_outer_lv == 0) {
            cur_outer_lv = lv
            cur_keep     = matches(ht)
        }
        # lv >= 4 with cur_outer_lv set: inherit cur_keep from parent
        if (cur_keep) out_body = out_body $0 "\n"
        next
    }

    { if (cur_keep) out_body = out_body $0 "\n" }

    END {
        printf "%s", out_fm
        printf "%s", out_body
        if (out_sig != "") printf "%s", out_sig
    }
    ' "$file" > "${file}.tmp"

    # Safety net: abort compaction if output < 20% of input
    local in_size out_size
    in_size=$(wc -c < "$file")
    out_size=$(wc -c < "${file}.tmp")
    if [ "$in_size" -gt 0 ] && [ $((out_size * 100 / in_size)) -lt 20 ]; then
        echo "n1_compact_memory: output is ${out_size}/${in_size} bytes (<20%), aborting compaction" >&2
        rm -f "${file}.tmp" "${file}.full.md"
        rm -f "$tmpkeep"
        return 1
    fi

    mv "${file}.tmp" "$file"

    rm -f "$tmpkeep"
}
