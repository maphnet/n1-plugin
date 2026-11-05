#!/usr/bin/env bash
# lib/release.sh -- release scope helpers, Confluence Result parser and readiness signal (N1-176).
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

# n1_release_page_results: stdin is a jcm_getArticle body. Prints <case-id><TAB><result> for rows of the first
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
            for (i = 1; i <= n; i++) { if (c[i] == "ID") id = i; if (c[i] == "Result") res = i }
            if (id && res) { idc = id; rc = res }
            next
        }
        {
            cells($0, c)
            if (c[idc] ~ /^RT-[0-9]+$/ && c[rc] != "") print c[idc] "\t" c[rc]
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
