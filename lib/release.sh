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

# n1_release_obs_group <cutoff-iso>: groups untrusted dev observability rows for release-test Step 3b.
# stdin: <first-ts>\t<last-ts>\t<count>\t<text>; timestamps ISO-8601 (Z, offset or none, optional fraction) or
# epoch s/ms/us/ns. stdout, newest last-seen first, times in UTC:
#   <signature>\t<count>\t<first>\t<last>\t<new since release|pre-existing>\t<sample>
# Signature: lowercased, timestamps -> {ts}, UUIDs and hex runs of 8+ with a letter -> {id}, digits -> {n}, 120 chars.
# Sample: first row's text, 160 chars. Both are redacted to {redacted}: URL userinfo (anything between :// and the last @ of the word),
# Bearer tokens, Authorization scheme+credential, Slack tokens/webhook paths, Google AIza keys, everything after a
# "cookie:" header, key=value / key: value / JSON (quoted, spaces, backslash-escaped) secrets whose key contains
# token secret password passwd pwd api/access/private key credential cookie session id sessid sid jwt auth sig,
# and 32+ char token runs. Over-redacting is the safe direction. Both are also stripped of control characters and | ` $ < > \, so they are safe in a one-line table cell.
# New since release: the group's earliest first-seen is at or after the cutoff. Merge: min first, max last, sum count.
# Rows with a bad timestamp or count are dropped and counted on stderr ("dropped: N"). Bad cutoff: no output. rc 0.
# ponytail: the label only sees the rows the provider returned (bounded, newest first); older lines crowded out by
# the limit read as new since release, the safe direction (a condition, never NO-GO). Per-signature baseline
# queries are the upgrade if the live false-positive rate is high.
n1_release_obs_group() {
    awk -F'\t' -v cutoff="${1:-}" '
        function days(y, m, d,   era, yoe, doy) {
            y -= (m <= 2); era = int(y / 400); yoe = y - era * 400
            doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
            return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
        }
        function epoch(x,   t, rest, off, n) {
            n = length(x)
            if (x ~ /^[0-9]+$/ && (n == 10 || n == 13 || n == 16 || n == 19)) return substr(x, 1, 10) + 0
            if (x !~ /^[0-9][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9][Tt ][0-2][0-9]:[0-5][0-9]:[0-6][0-9]/) return -1
            t = days(substr(x, 1, 4) + 0, substr(x, 6, 2) + 0, substr(x, 9, 2) + 0) * 86400 \
                + substr(x, 12, 2) * 3600 + substr(x, 15, 2) * 60 + substr(x, 18, 2)
            rest = substr(x, 20); sub(/^\.[0-9]+/, "", rest)
            if (rest == "" || rest == "Z" || rest == "z") return t
            if (rest !~ /^[+-][0-2][0-9]:?[0-5][0-9]$/) return -1
            off = substr(rest, 2, 2) * 3600 + substr(rest, length(rest) - 1, 2) * 60
            return substr(rest, 1, 1) == "-" ? t + off : t - off
        }
        function iso(t,   s, z, era, doe, yoe, doy, mp, d, m) {
            s = t % 86400; z = (t - s) / 86400 + 719468
            era = int(z / 146097); doe = z - era * 146097
            yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
            doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
            mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
            m = mp + (mp < 10 ? 3 : -9)
            return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", yoe + era * 400 + (m <= 2), m, d, int(s / 3600), int(s % 3600 / 60), s % 60)
        }
        function redact(s, re,   l, out) {
            l = tolower(s); out = ""
            while (match(l, re)) {
                out = out substr(s, 1, RSTART - 1) "{redacted}"
                s = substr(s, RSTART + RLENGTH); l = substr(l, RSTART + RLENGTH)
            }
            return out s
        }
        function squeeze(s) { gsub(/ +/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
        BEGIN {
            c = "[A-Za-z0-9+=_]"; LONG = c; for (i = 1; i < 32; i++) LONG = LONG c; LONG = LONG "*"
            h = "[0-9a-f]"; h4 = h h h h; HEX8 = h4 h4 h "*"
            UUID = h4 h4 "-" h4 "-" h4 "-" h4 "-" h4 h4 h4
            TS = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][t ][0-9][0-9]:[0-9][0-9]:[0-9][0-9](\\.[0-9]+)?(z|[+-][0-9][0-9]:?[0-9][0-9])?"
            KW = "(token|secret|password|passwd|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential|cookie|session[_-]?id|sessid|sid|jwt|auth|sig)"
            KB = KW "[a-z_-]*[\\\\\"\047 ]*[=:][ ]*"
            KQ1 = KB "\\\\*\"[^\"]*\"?"; KQ2 = KB "\047[^\047]*\047?"; KU = KB "[^ \",;&\047\\\\]+"
            AUTH = "authorization[\\\\\"\047 ]*[=:][ ]*[\\\\\"\047]*[a-z]+[ ]+[^ \",\047\\\\]+"
            COOKIE = "cookie[a-z_-]*[ ]*:.*"
            AIZA = "aiza"; for (i = 0; i < 20; i++) AIZA = AIZA "[a-z0-9_-]"; AIZA = AIZA "[a-z0-9_-]*"
            cut = epoch(cutoff)
        }
        cut < 0 { next }
        {
            first = epoch($1); last = epoch($2)
            if (NF < 4 || first < 0 || last < 0 || $3 !~ /^[0-9]+$/) { dropped++; next }
            if (last < first) { x = first; first = last; last = x }
            text = $0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", text)
            gsub(/[[:cntrl:]]/, " ", text)
            text = redact(text, "://[^ ]*@")
            text = redact(redact(redact(redact(redact(redact(text, "bearer[ ]+[^ ]+"), "xox[a-z][-.][^ ]+"), "xapp-[^ ]+"), "hooks[.]slack[.]com/services/[^ ]+"), AIZA), COOKIE)
            text = redact(redact(redact(redact(redact(text, AUTH), KQ1), KQ2), KU), LONG)
            gsub(/[|`$<>\\]/, " ", text); text = squeeze(text)
            s = tolower(text); gsub(TS, "{ts}", s); gsub(UUID, "{id}", s)
            out = ""
            while (match(s, HEX8)) {
                r = substr(s, RSTART, RLENGTH)
                out = out substr(s, 1, RSTART - 1) (r ~ /[a-f]/ ? "{id}" : r)
                s = substr(s, RSTART + RLENGTH)
            }
            s = out s; gsub(/[0-9]+/, "{n}", s); s = substr(squeeze(s), 1, 120)
            if (!(s in cnt)) { lo[s] = first; hi[s] = last; sample[s] = substr(text, 1, 160) }
            else { if (first < lo[s]) lo[s] = first; if (last > hi[s]) hi[s] = last }
            cnt[s] += $3
        }
        END {
            if (dropped) print "dropped: " dropped > "/dev/stderr"
            for (s in cnt) printf "%.0f\t%s\t%.0f\t%s\t%s\t%s\t%s\n", hi[s], s, cnt[s], iso(lo[s]), iso(hi[s]), \
                (lo[s] >= cut ? "new since release" : "pre-existing"), sample[s]
        }
    ' | sort -t $'\t' -k1,1nr -k2,2 | cut -f2-
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

# n1_release_signal <verified|unverified> [<warning-count>] [<new-obs-groups>]: stdin lines are <risk><TAB><class><TAB><status>.
# Prints NO-GO, GO with conditions or GO, then one "condition: ..." line per condition (D2, D4).
# Fails closed: a FAIL with no Low/Medium tier is NO-GO, an unknown status is UNVERIFIED, no cases is a condition.
# New-since-release dev observability groups (N1-179) are a condition only; they never reach NO-GO.
n1_release_signal() {
    local build="${1:-unverified}" warn="${2:-0}" obs="${3:-0}"
    [[ "$warn" =~ ^[0-9]+$ ]] || warn=1
    [[ "$obs" =~ ^[0-9]+$ ]] || obs=1
    awk -F'\t' -v build="$build" -v warn="$warn" -v obs="$obs" '
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
            if (obs + 0 > 0) cond = cond "condition: " obs " new-since-release dev observability group(s)\n"
            if (build != "verified") cond = cond "condition: dev build not verified as HEAD\n"
            print (nogo ? "NO-GO" : (cond != "" ? "GO with conditions" : "GO"))
            printf "%s", cond
        }
    '
}
