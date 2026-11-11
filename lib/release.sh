#!/usr/bin/env bash
# lib/release.sh -- release scope helpers, blocker-link parser (N1-539), Confluence Result parser and readiness signal (N1-176).
# Callers: skills/n1-release steps 01 and 03b, skills/n1-release-test. Source after the preamble.
_N1_RELEASE_TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$'

# n1_release_prev_tag [<tag> | --exclude <tag>]: prints a plain-semver tag or nothing; rc 0.
#   no argument:   newest v* tag, else the gh release list fallback.
#   --exclude <t>: same, skipping <t>, so a retry after tag-created-but-release-failed keeps its range.
#   <tag>:         the next v* tag older than <tag>, no gh; empty when <tag> is absent or oldest.
# Tag names come from the remote and may carry shell metacharacters, so only plain semver is printed.
n1_release_prev_tag() {
    local tag="" exclude="" prev
    case "${1:-}" in
        --exclude) exclude="${2:-}" ;;
        *) tag="${1:-}" ;;
    esac
    if [ -n "$tag" ]; then
        prev=$(git tag --list 'v*' --sort=-version:refname | awk -v t="$tag" 'f {print; exit} $0 == t {f = 1}')
    else
        prev=$(git tag --list 'v*' --sort=-version:refname | grep -v -x -- "$exclude" | head -1)
        if [ -z "$prev" ]; then
            prev=$(gh release list --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
            [ "$prev" = "$exclude" ] && prev=""
        fi
    fi
    [[ "$prev" =~ $_N1_RELEASE_TAG_RE ]] && printf '%s\n' "$prev"
    return 0
}

# n1_release_tag_date <tag>: ISO-8601 creation date of a local v* tag (tagger date of an annotated tag, commit
# date of a lightweight one). Prints nothing for an absent or non-semver tag; rc 0. Release-test Step 3b window start.
n1_release_tag_date() {
    local tag="${1:-}"
    [[ "$tag" =~ $_N1_RELEASE_TAG_RE ]] || return 0
    git for-each-ref --format='%(creatordate:iso-strict)' "refs/tags/$tag" 2>/dev/null
    return 0
}

# n1_release_obs_window <tag>: prints "<hours> <capped|full> <baseline-hours>" for the dev observability scan:
# whole hours from the tag's creation to now (rounded up, at least 1), capped at N1_OBS_MAX_HOURS (default 720),
# and the Loki/Langfuse baseline reach, twice the window under the same cap. Nothing for an absent tag; rc 0.
# ponytail: the cap is a constant because provider retention is not discoverable; the report states when it applied.
n1_release_obs_window() {
    local tag="${1:-}" max="${N1_OBS_MAX_HOURS:-720}" from h b cap=full
    [[ "$tag" =~ $_N1_RELEASE_TAG_RE ]] || return 0
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=720
    from=$(git for-each-ref --format='%(creatordate:unix)' "refs/tags/$tag" 2>/dev/null)
    [[ "$from" =~ ^[0-9]+$ ]] || return 0
    h=$(( ($(date +%s) - from + 3599) / 3600 ))
    [ "$h" -ge 1 ] || h=1
    if [ "$h" -gt "$max" ]; then h=$max; cap=capped; fi
    b=$((h * 2))
    [ "$b" -gt "$max" ] && b=$max
    printf '%s %s %s\n' "$h" "$cap" "$b"
    return 0
}

# n1_release_obs_providers [config-file]: dev observability providers for release-test Step 3b, read regardless of
# observability.default. One row per provider with env "dev": <name>\t<mcp>\t<kind>\t<tool>, where kind comes from
# the operation key (query -> loki, searchIssues -> sentry, findExceptions -> langfuse). Providers with none of these,
# or with a name, mcp or tool outside [A-Za-z0-9_.-], are dropped. No file or no jq: nothing; rc 0.
n1_release_obs_providers() {
    local file="${1:-$(n1_config_file)}"
    [ -f "$file" ] && command -v jq >/dev/null 2>&1 || return 0
    jq -r '
        (.observability.providers // {}) | if type == "object" then to_entries[] else empty end
        | select((.value | type) == "object" and .value.env == "dev")
        | .key as $n | .value as $p
        | (if ($p.operations | type) == "object" then $p.operations else {} end) as $o
        | (if ($o.query | type) == "string" then ["loki", $o.query]
           elif ($o.searchIssues | type) == "string" then ["sentry", $o.searchIssues]
           elif ($o.findExceptions | type) == "string" then ["langfuse", $o.findExceptions]
           else empty end) as $k
        | [$n, ($p.mcp // "" | tostring), $k[0], $k[1]] | @tsv' "$file" 2>/dev/null \
        | awk -F'\t' 'NF == 4 && $1 ~ /^[A-Za-z0-9_.-]+$/ && $2 ~ /^[A-Za-z0-9_.-]+$/ && $4 ~ /^[A-Za-z0-9_.-]+$/'
    return 0
}

# n1_release_ticket_ids <prev> <head-ref>: IDs from the leading [PREFIX-N] of each commit subject in prev..head
# (all of head when prev is empty). IDs later in a subject and untagged subjects count for nothing.
# --no-decorate: log.decorate would put "(tag: ..)" after the hash. PREFIX: env, else .tracker.prefix.
n1_release_ticket_ids() {
    local prev="${1:-}" head="${2:-HEAD}" prefix="${PREFIX:-$(n1_config_val '.tracker.prefix')}" log
    if [ -n "$prev" ]; then
        log=$(git log "${prev}..${head}" --oneline --no-decorate 2>/dev/null || true)
    else
        log=$(git log "${head}" --oneline --no-decorate 2>/dev/null || true)
    fi
    sed -nE "s/^[0-9a-f]+ \[(${prefix}-[0-9]+)\].*/\1/p" <<<"$log" | sort -u
}

# n1_release_blockers <release-ids>: stdin lines <TICKET><TAB><jcm_getIssueLinks JSON array on one line>.
# Prints <BLOCKER><TAB><T1,T2,...> once per blocker outside <release-ids> (newline separated), sorted; rc 0.
# A Blocks link with inwardIssue means the queried ticket "is blocked by" that key (references/blocker-check.md).
# Keys failing ^[A-Z][A-Z0-9_]*-[0-9]+$, non-arrays and malformed JSON are dropped: tracker data is untrusted (N1-539 D7).
# ponytail: jc-mcp shape only (type name + bare keys); a renamed blocking link type or YouTrack relations give no rows.
n1_release_blockers() {
    local ids="${1:-}" re='^[A-Z][A-Z0-9_]*-[0-9]+$' t j b
    while IFS=$'\t' read -r t j; do
        [[ "$t" =~ $re ]] || continue
        while IFS= read -r b; do
            [[ "$b" =~ $re ]] || continue
            grep -qxF -- "$b" <<<"$ids" && continue
            printf '%s\t%s\n' "$b" "$t"
        done < <(jq -r 'if type == "array" then .[] else empty end
            | select(type == "object" and .type == "Blocks" and (.inwardIssue | type) == "string")
            | .inwardIssue' <<<"$j" 2>/dev/null)
    done | LC_ALL=C sort -u | LC_ALL=C awk -F'\t' '
        $1 != k { if (k != "") print k "\t" v; k = $1; v = $2; next }
        { v = v "," $2 }
        END { if (k != "") print k "\t" v }'
    return 0
}

# n1_release_blocker_rows <done-status> [<prefix>]: stdin lines <KEY><TAB><status><TAB><tickets><TAB><title>
# (title last; extra tabs are joined into it). Prints <KEY><TAB><done|not done><TAB><owner><TAB><status><TAB><tickets><TAB><title>.
# done: status equals <done-status> case-insensitively; an empty <done-status> or status is "not done" (fails toward warning).
# owner: title service tag "<service> | ...", else the key prefix when it differs from <prefix>, else "unknown".
# <prefix>: argument, else PREFIX env, else .tracker.prefix. Rows whose key fails the key pattern are dropped.
# ponytail: the tag rule mirrors n1_story_parse_service (lib/queue.sh), which is not sourced here (needs config/host/frontmatter); change both together.
n1_release_blocker_rows() {
    local ds="${1:-}" prefix="${2:-${PREFIX:-$(n1_config_val '.tracker.prefix')}}"
    LC_ALL=C awk -F'\t' -v d="$ds" -v p="$prefix" '
        { sub(/\r$/, "") }
        $1 !~ /^[A-Z][A-Z0-9_]*-[0-9]+$/ { next }
        {
            st = $2; gsub(/^[ \t]+|[ \t]+$/, "", st)
            t = $4; for (i = 5; i <= NF; i++) t = t " " $i
            state = (d != "" && st != "" && tolower(st) == tolower(d)) ? "done" : "not done"
            own = ""; x = index(t, " |")
            if (x) { own = substr(t, 1, x - 1); sub(/[ \t]+$/, "", own) }
            if (own == "") { k = $1; sub(/-[0-9]+$/, "", k); own = (k != p) ? k : "unknown" }
            print $1 "\t" state "\t" own "\t" st "\t" $3 "\t" t
        }'
}

# n1_release_page_results: stdin is a jcm_getArticle body. Prints <case-id><TAB><result>[<TAB><tested-at>] for rows of the first
# table with ID and Result columns whose Result is non-empty. rc 1 when there is no such table: the caller
# must then not overwrite the page.
# ponytail: pinned to the jc-mcp 0.11.1 one-line pipe rows (adf-to-markdown.js tableToMarkdown); a format change
# gives rc 1, not data loss. Refresh the sample in tests/test_release.sh when jc-mcp changes it.
n1_release_page_results() {
    awk '
        function cells(line, a,   n, i) {
            gsub(/\\\|/, "\001", line)
            n = split(line, a, "|")
            for (i = 1; i <= n; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", a[i])
                gsub(/\001/, "|", a[i])
            }
            return n
        }
        $0 !~ /^[ \t]*\|/ { if (idc) exit; next }
        !idc {
            n = cells($0, c); id = 0; res = 0
            tat = 0
            for (i = 1; i <= n; i++) { if (c[i] == "ID") id = i; if (c[i] == "Result") res = i; if (c[i] == "Tested at") tat = i }
            if (id && res) { idc = id; rc = res; tc = tat }
            next
        }
        {
            cells($0, c)
            if (c[idc] ~ /^RT-[0-9]+$/ && c[rc] != "") print c[idc] "\t" c[rc] (tc ? "\t" c[tc] : "")
        }
        END { exit (idc ? 0 : 1) }
    '
}

# n1_release_signal <verified|unverified> [<warning-count>]: stdin lines are <risk><TAB><class><TAB><status>.
# Prints NO-GO, GO with conditions or GO, then one "condition: ..." line per condition (D2, D4).
# Fails closed: a FAIL with no Low/Medium tier is NO-GO, an unknown status is UNVERIFIED, no cases is a condition.
n1_release_signal() {
    local build="${1:-unverified}" warn="${2:-0}"
    [[ "$warn" =~ ^[0-9]+$ ]] || warn=1
    awk -F'\t' -v build="$build" -v warn="$warn" '
        /^[[:space:]]*$/ { next }
        {
            total++
            risk = tolower($1); status = toupper($3)
            if (status == "PASS") next
            if (status == "FAIL") { if (risk == "low" || risk == "medium") lowfail++; else nogo++; next }
            if (status == "MANUAL" || status == "PENDING") pending++; else unverified++
        }
        END {
            if (!total) cond = cond "condition: no test cases\n"
            if (unverified) cond = cond "condition: " unverified " UNVERIFIED case(s)\n"
            if (pending) cond = cond "condition: " pending " pending MANUAL or assisted case(s)\n"
            if (lowfail) cond = cond "condition: " lowfail " Low/Medium FAIL case(s)\n"
            if (warn + 0 > 0) cond = cond "condition: " warn " scope or publish warning(s)\n"
            if (build != "verified") cond = cond "condition: dev build not verified as HEAD\n"
            print (nogo ? "NO-GO" : (cond != "" ? "GO with conditions" : "GO"))
            printf "%s", cond
        }
    '
}
