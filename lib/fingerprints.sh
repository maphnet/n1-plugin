#!/usr/bin/env bash
# N1 cross-pass finding fingerprint helpers.
# Persistence format: JSONL in $N1_HOME/memory/<ID>/fingerprints.jsonl
# Each line: {"fp":"<hex>","id":"<CR-1>","severity":"High","status":"active","cycle":1,"ts":"..."}
# N1-569 state rows add "age" after "cycle"; status active|carried|new = open, resolved|withdrawn|downgraded|oos = closed.

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
    # Usage: n1_fingerprint_append <jsonl_file> <fingerprint> <finding_id> <severity> <status> [cycle] [age]
    # status: active (recorded review finding) or an N1-569 fix state; age (fix cycles survived) follows "cycle" when given.
    local jsonl_file="$1" fp="$2" fid="$3" severity="$4" status="$5" cycle="${6:-1}" age="${7:-}"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$jsonl_file")"
    [ -n "$age" ] && age=",\"age\":$age"
    printf '{"fp":"%s","id":"%s","severity":"%s","status":"%s","cycle":%s%s,"ts":"%s"}\n' \
        "$fp" "$fid" "$severity" "$status" "$cycle" "$age" "$ts" >> "$jsonl_file"
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
    # Prints count of distinct open (active|carried|new) Critical/High fingerprints
    local jsonl_file="$1"
    [ -f "$jsonl_file" ] || { printf '0'; return; }
    # Get the latest status for each fingerprint, count those that are open (active|carried|new) + Critical/High
    if command -v jq >/dev/null 2>&1; then
        # jq: group by fp, take last entry per fp, filter open (active|carried|new) + Critical/High
        jq -s '
            group_by(.fp) | map(last) |
            map(select((.status | test("^(active|carried|new)$")) and (.severity == "Critical" or .severity == "High"))) |
            length
        ' "$jsonl_file" 2>/dev/null || printf '0'
    else
        # Fallback: grep for open (active|carried|new) Critical/High, extract unique fps
        grep -E '"status":"(active|carried|new)"' "$jsonl_file" 2>/dev/null \
            | grep -E '"severity":"(Critical|High)"' \
            | grep -o '"fp":"[^"]*"' | sort -u | wc -l | tr -d ' '
    fi
}

n1_fingerprint_blocking_count_for_cycle() {
    # Usage: n1_fingerprint_blocking_count_for_cycle <jsonl_file> <cycle>
    # Prints count of distinct open (active|carried|new) Critical/High fingerprints for the given cycle number
    local jsonl_file="$1" cycle="$2"
    [ -f "$jsonl_file" ] || { printf '0'; return; }
    if command -v jq >/dev/null 2>&1; then
        jq -s --argjson c "$cycle" '
            map(select(.cycle == $c)) |
            group_by(.fp) | map(last) |
            map(select((.status | test("^(active|carried|new)$")) and (.severity == "Critical" or .severity == "High"))) |
            length
        ' "$jsonl_file" 2>/dev/null || printf '0'
    else
        # Fallback: filter by cycle field, grep for open (active|carried|new) Critical/High, count unique fps
        grep "\"cycle\":${cycle}" "$jsonl_file" 2>/dev/null \
            | grep -E '"status":"(active|carried|new)"' \
            | grep -E '"severity":"(Critical|High)"' \
            | grep -o '"fp":"[^"]*"' | sort -u | wc -l | tr -d ' '
    fi
}

n1_review_blocking_index_count() {
    # Usage: n1_review_blocking_index_count <review-hdr.md> (N1-483)
    # Prints the number of Index lines `- [ID] <severity> <file>:<line> — <title>` that fail review
    # (skills/n1-start/steps/review.md FAIL rule): Critical/High, any [RULE-N], and a non-Low [SEC-N];
    # a [SEC-N] whose title ends " (pre-existing)" never counts. Prints 0 and returns 1 on an unreadable file.
    [ -r "$1" ] || { printf '0'; return 1; }
    awk '
        /^- \[[A-Z]+-[0-9]+\] / {
            id = $2; sev = tolower($3)
            if (id ~ /^\[SEC-/ || (id ~ /^\[CX-/ && $0 ~ / \(security\)[ \t]*$/)) {
                if ($0 ~ / \(pre-existing\)[ \t]*$/) next
                if (sev != "low") n++
                next
            }
            if (id ~ /^\[RULE-/ || sev == "critical" || sev == "high") n++
        }
        END { printf "%d", n }
    ' "$1"
}

n1_review_blocking_ids() {
    # Usage: n1_review_blocking_ids <review.md> (N1-569) -> one TSV row per blocking Index line `- [ID] <sev> <file>:<line> — <title>`,
    # first occurrence of each ID: <id>\t<severity>\t<file>\t<title>. Blocking (D7, = the fix.md FAIL dispatch scope):
    # Critical/High; any [RULE-N]; non-Low [SEC-N] (and [CX-N] titled " (security)"); non-TQ Medium. A " (pre-existing)"
    # [SEC-N], security [CX-N] or Medium never counts. File = location before the last ':'. Returns 1 on an unreadable file.
    [ -r "$1" ] || return 1
    awk '
        /^- \[[A-Z]+-[0-9]+\] / {
            sub(/\r$/, "")
            id = substr($2, 2, length($2) - 2); if (seen[id]++) next
            sev = $3; ls = tolower(sev); pre = ($0 ~ / \(pre-existing\)[ \t]*$/)
            if (id ~ /^SEC-/ || (id ~ /^CX-/ && $0 ~ / \(security\)[ \t]*$/)) { if (pre || ls == "low") next }
            else if (!(id ~ /^RULE-/ || ls == "critical" || ls == "high" || (ls == "medium" && id !~ /^TQ-/ && !pre))) next
            rest = $0; sub(/^- \[[A-Z]+-[0-9]+\] [^ ]+ /, "", rest)
            i = index(rest, " — ")
            if (i) { loc = substr(rest, 1, i - 1); title = substr(rest, i + length(" — ")) } else { loc = ""; title = rest }
            file = loc; if (match(loc, /:[^:]*$/)) file = substr(loc, 1, RSTART - 1)
            gsub(/\t/, " ", title)
            printf "%s\t%s\t%s\t%s\n", id, sev, file, title
        }' "$1"
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

n1_fingerprint_filter_oos() {
    # Usage: n1_fingerprint_filter_oos <jsonl> <cycle> <fix-changed-files> <review-prev.md> <index-file>
    # Every incremental re-review (N1-345 D20, N1-569). Removes from <index-file> each Index line
    # `- [ID] <severity> <file>:<line> — <title>` (any severity/prefix) that is new and out of the fix's reach:
    # no <review-prev.md> Index line with the same ID and file, fingerprint (file before the last ':', title) absent from bucket <cycle>-1,
    # and file (./ stripped, case-insensitive) absent from <fix-changed-files>. Prints the removed lines verbatim.
    # Fail-safe: a missing/empty input, cycle < 1, an unparsable line, a location that is not one repo-relative
    # path (absolute, a/ b/ prefix, list), any [SEC-N] finding, or a title naming a security class (any prefix,
    # case-insensitive substring; review-core.md SECURITY_RELEVANT) keeps the finding in the loop.
    # A failed write to the temp index aborts: original index kept, non-zero return.
    # Reviewer text is read from files as data, never placed in shell command text (N1-136).
    local jsonl="$1" cycle="$2" fixf="$3" prev="$4" idx="$5" sep=' — '
    local line id sev rest loc file title fp norm bucket fixl tmp pl out=""
    [[ "$cycle" =~ ^[0-9]+$ ]] && [ "$cycle" -ge 1 ] && [ -s "$fixf" ] && [ -r "$prev" ] && [ -r "$jsonl" ] && [ -r "$idx" ] || return 0
    bucket=$(grep "\"cycle\":$((cycle - 1))," "$jsonl" 2>/dev/null)
    fixl=$(sed 's|^\./||' "$fixf" | tr '[:upper:]' '[:lower:]')
    tmp=$(mktemp "${idx}.XXXXXX") || return 1
    : > "$tmp" || { rm -f "$tmp"; return 1; }
    local kw tl seckw=(auth crypto "input validation" secret credential token network http ssrf serializ "path traversal" "file path" "path handling" sql query inject shell "command exec" quoting xss csrf toctou race symlink privilege eval sandbox "untrusted input")
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^-\ \[([A-Z]+-[0-9]+)\]\ ([^ ]+)\ (.+)$ ]]; then
            id=${BASH_REMATCH[1]}; sev=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[3]}
            if [[ "$rest" == *"$sep"* ]]; then
                loc=${rest%%"$sep"*}; title=${rest#*"$sep"}
                tl=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')
                for kw in "${seckw[@]}"; do [[ "$tl" == *"$kw"* ]] && { id=SEC-0; break; }; done
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
        printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
    done < "$idx"
    if mv -f "$tmp" "$idx"; then printf '%s' "$out"; else rm -f "$tmp"; return 1; fi
}

_n1_blocking_tsv() {
    # Usage: _n1_blocking_tsv <review.md> -> n1_review_blocking_ids rows plus a 5th column, the fingerprint.
    local id sev file title
    while IFS=$'\t' read -r id sev file title; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$sev" "$file" "$title" "$(n1_fingerprint_finding "$file" "$title")"
    done < <(n1_review_blocking_ids "$1")
}

n1_fix_states() {
    # Usage: n1_fix_states <memory dir> <cycle> (N1-569) -> prints "resolved=R carried=C new=N unlabeled=U";
    # returns 1 (no output) when cycle < 1 or review-prev.md / review.md is unreadable.
    # Per prior blocking ID (review-prev.md) appends one row in bucket <cycle> of fingerprints.jsonl. review-status.md
    # `- [ID] FIXED|WITHDRAWN|DOWNGRADED|OOS` -> resolved|withdrawn|downgraded|oos, unless the new review.md still lists
    # the same ID in the same file as blocking (then carried); `OPEN` -> carried; `OPEN as [X]` -> carried under X.
    # No line (unlabeled): same ID + same file, else same fingerprint -> carried; else resolved. carried age = prior
    # age (last open row of the ID in bucket <cycle>-1, default 0) + 1. Other blocking IDs of review.md -> new, age 0.
    # Reviewer text is read from files as data, never placed in shell command text (N1-136).
    local mem="$1" cyc="$2" fpj="$1/fingerprints.jsonl" st="$1/review-status.md" ages=/dev/null
    local s id sev fp age r=0 c=0 n=0 u=0
    [[ "$cyc" =~ ^[0-9]+$ ]] && [ "$cyc" -ge 1 ] && [ -r "$mem/review-prev.md" ] && [ -r "$mem/review.md" ] || return 1
    [ -r "$st" ] || st=/dev/null
    [ -r "$fpj" ] && ages=$fpj
    while IFS=$'\t' read -r s id sev fp age; do
        case "$s" in
            summary) u=$id; continue ;;
            carried) c=$((c + 1)) ;;
            new) n=$((n + 1)) ;;
            *) r=$((r + 1)) ;;
        esac
        n1_fingerprint_append "$fpj" "$fp" "$id" "$sev" "$s" "$cyc" "$age"
    done < <(awk -v cyc="$cyc" '
        BEGIN { FS = "\t" }
        FILENAME == ARGV[1] {
            sub(/\r$/, "")
            if (match($0, /^- \[[A-Z]+-[0-9]+\] /)) {
                id = substr($0, 4, RLENGTH - 5); rest = substr($0, RLENGTH + 1)
                if (match(rest, /^OPEN as \[[A-Z]+-[0-9]+\]/)) { st[id] = "OPEN"; al[id] = substr(rest, 10, RLENGTH - 10) }
                else if (match(rest, /^(FIXED|OPEN|WITHDRAWN|DOWNGRADED|OOS)([ \t]|$)/)) { split(rest, w, /[ \t]/); st[id] = w[1] }
            }
            next
        }
        FILENAME == ARGV[2] {
            if (index($0, "\"cycle\":" (cyc - 1) ",") && $0 ~ /"status":"(active|carried|new)"/ && match($0, /"id":"[A-Z]+-[0-9]+"/)) {
                id = substr($0, RSTART + 6, RLENGTH - 7); a = 0
                if (match($0, /"age":[0-9]+/)) a = substr($0, RSTART + 6, RLENGTH - 6) + 0
                age[id] = a
            }
            next
        }
        FILENAME == ARGV[3] { if (!($1 in pf)) pid[++np] = $1; psev[$1] = $2; pf[$1] = $3; pfp[$1] = $5; next }
        {
            if (!($1 in cf)) cid[++nc] = $1
            csev[$1] = $2; cf[$1] = $3; cfp[$1] = $5; if (!($5 in byfp)) byfp[$5] = $1
        }
        END {
            for (i = 1; i <= np; i++) {
                p = pid[i]; s = st[p]; x = ""
                if (s == "") {
                    u++
                    if ((p in cf) && cf[p] == pf[p]) x = p
                    else if (pfp[p] in byfp) x = byfp[pfp[p]]
                } else if (s == "OPEN") x = (p in al) ? al[p] : p
                else if ((p in cf) && cf[p] == pf[p]) x = p
                a = (p in age) ? age[p] : 0
                if (x == "") {
                    o = (s == "WITHDRAWN") ? "withdrawn" : (s == "DOWNGRADED") ? "downgraded" : (s == "OOS") ? "oos" : "resolved"
                    print o "\t" p "\t" psev[p] "\t" pfp[p] "\t" a
                } else if ((x in cf) && !(x in used)) { used[x] = 1; print "carried\t" x "\t" csev[x] "\t" cfp[x] "\t" (a + 1) }
                else print "carried\t" p "\t" psev[p] "\t" pfp[p] "\t" (a + 1)
            }
            for (i = 1; i <= nc; i++) if (!(cid[i] in used)) print "new\t" cid[i] "\t" csev[cid[i]] "\t" cfp[cid[i]] "\t0"
            print "summary\t" (u + 0)
        }' "$st" "$ages" <(_n1_blocking_tsv "$mem/review-prev.md") <(_n1_blocking_tsv "$mem/review.md"))
    printf 'resolved=%s carried=%s new=%s unlabeled=%s\n' "$r" "$c" "$n" "$u"
}
