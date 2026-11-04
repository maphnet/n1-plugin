#!/usr/bin/env bash
# lib/ci_rerun.sh — n1-ci reruns flaky/infra failures before developer dispatch (N1-341).
# State in overview.md frontmatter, beside ci_fix_cycle: ci_rerun_sha (head SHA the count belongs to),
# ci_rerun_count (checks rerun at that SHA), ci_rerun_checks (space-separated sha256 of rerun check names).
# Cap: 3 reruns per head SHA across all checks; a new head SHA resets all three keys. ci_fix_cycle is never
# written here. Every failure path prints dispatch (existing developer/escalation path). Logs are only
# grepped, never printed. Rules: skills/n1-ci/steps/02-fix.md Step 5.
_N1_CI_RERUN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_N1_CI_RERUN_LIB/frontmatter.sh"
source "$_N1_CI_RERUN_LIB/treestate.sh"

_N1_CI_RERUN_CAP=3
_N1_CI_INFRA_NAME='timeout|runner|infrastructure'
_N1_CI_INFRA_LOG='runner .*(lost communication|shutdown)|shutdown signal|No space left on device|ETIMEDOUT|ECONNRESET|ENOTFOUND|connection (timed out|reset)|TLS handshake timeout|Could not resolve host|Temporary failure in name resolution|50[234] (Bad Gateway|Service Unavailable|Gateway Time-?out)|429 Too Many Requests|timed out'
_N1_CI_ASSERT_LOG='AssertionError|expected .* (to|but)|(^|[[:space:]])FAIL[: ]|[1-9][0-9]* (tests? )?failed'

# n1_ci_log_infra <run-id>: rc 0 when the failed-job log (last 500 lines) shows a runner, network or
# timeout failure and no assertion. Any error, empty log or no match -> rc 1. Prints nothing.
n1_ci_log_infra() {
    local log
    [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
    log=$(timeout -k 5 45 gh run view "$1" --log-failed 2>&1) || return 1
    log=$(tail -n 500 <<<"$log")
    [ -n "$log" ] || return 1
    grep -Eq "$_N1_CI_INFRA_LOG" <<<"$log" && ! grep -Eq "$_N1_CI_ASSERT_LOG" <<<"$log"
}

# n1_ci_rerun_gate <overview.md> <pr#> <fail-tsv> [escalate-ere]: prints dispatch or rerun:<k>/<cap>; rc 0.
# <fail-tsv> holds poll lines FAIL<TAB>name<TAB>link. All failed checks must be eligible (Actions run link,
# no escalate match, not rerun before at this SHA, infra name or infra log) and fit under the cap.
n1_ci_rerun_gate() {
    local o="$1" pr="$2" tsv="$3" esc="${4:-}" sha count old tag="" name link id i rc ok=0 newh=""
    local -a ids=() hs=() names=()
    [ -f "$o" ] && [[ "$pr" =~ ^[0-9]+$ ]] && [ -s "$tsv" ] || { echo dispatch; return 0; }
    while IFS=$'\t' read -r tag name link || [ -n "$tag" ]; do
        [ "$tag" = FAIL ] && [ -n "$name" ] || { tag=""; continue; }
        link=${link%$'\r'}
        [[ "$link" =~ ^https?://github\.com/[^/]+/[^/]+/actions/runs/([0-9]+)(/|$) ]] || { echo dispatch; return 0; }
        ids+=("${BASH_REMATCH[1]}"); names+=("$name"); hs+=("$(printf '%s\n' "$name" | _n1_sha256)")
        tag=""
    done < "$tsv"
    [ "${#ids[@]}" -gt 0 ] || { echo dispatch; return 0; }
    sha=$(timeout -k 5 30 gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null)
    [[ "$sha" =~ ^[0-9a-f]{40,64}$ ]] || { echo dispatch; return 0; }
    if [ "$sha" != "$(n1_read_frontmatter "$o" ci_rerun_sha)" ]; then
        { n1_write_frontmatter "$o" ci_rerun_sha "$sha" && n1_write_frontmatter "$o" ci_rerun_count 0 \
            && n1_write_frontmatter "$o" ci_rerun_checks ""; } || { echo dispatch; return 0; }
    fi
    count=$(n1_read_frontmatter "$o" ci_rerun_count); count=${count:-0}
    [[ "$count" =~ ^[0-9]+$ ]] || { echo dispatch; return 0; }
    (( count + ${#ids[@]} <= _N1_CI_RERUN_CAP )) || { echo dispatch; return 0; }
    old=$(n1_read_frontmatter "$o" ci_rerun_checks)
    for i in "${!ids[@]}"; do
        case " $old " in *" ${hs[$i]} "*) echo dispatch; return 0 ;; esac
        if [ -n "$esc" ]; then
            grep -Eiq -- "$esc" <<<"${names[$i]}"; rc=$?
            [ "$rc" -eq 1 ] || { echo dispatch; return 0; }   # match (0) or bad ERE (2)
        fi
        grep -Eiq "$_N1_CI_INFRA_NAME" <<<"${names[$i]}" || n1_ci_log_infra "${ids[$i]}" || { echo dispatch; return 0; }
    done
    # Count first: a failed write stops before any rerun, so reruns never run uncounted.
    n1_write_frontmatter "$o" ci_rerun_count "$((count + ${#ids[@]}))" || { echo dispatch; return 0; }
    for id in $(printf '%s\n' "${ids[@]}" | sort -u); do
        timeout -k 5 45 gh run rerun "$id" --failed >/dev/null 2>&1 || continue
        for i in "${!ids[@]}"; do
            [ "${ids[$i]}" = "$id" ] || continue
            ok=$((ok + 1)); newh="${newh:+$newh }${hs[$i]}"
        done
    done
    count=$((count + ok))
    n1_write_frontmatter "$o" ci_rerun_count "$count" || true
    [ "$ok" -gt 0 ] || { echo dispatch; return 0; }
    n1_write_frontmatter "$o" ci_rerun_checks "${old:+$old }$newh" || true
    echo "rerun:$count/$_N1_CI_RERUN_CAP"
}

# n1_ci_rerun_summary <overview.md>: "reran <N> flaky check(s) (<N>/<cap>)", nothing when none.
n1_ci_rerun_summary() {
    local k noun=checks
    k=$(n1_read_frontmatter "$1" ci_rerun_count)
    [[ "$k" =~ ^[0-9]+$ ]] && [ "$k" -gt 0 ] || return 0
    [ "$k" -eq 1 ] && noun=check
    printf 'reran %s flaky %s (%s/%s)\n' "$k" "$noun" "$k" "$_N1_CI_RERUN_CAP"
}
