#!/usr/bin/env bash
# N1 queue runner helpers (n1-queue). Pure functions; no MCP calls.
# Includes story-mode helpers migrated from lib/story.sh.
# Requires lib/config.sh, lib/host.sh, lib/frontmatter.sh sourced first.

n1_queue_val() {
    # Usage: n1_queue_val <key> — .queue.<key> from config, else defaults/queue.json.
    local key="$1" val
    val=$(n1_config_val ".queue.${key}")
    if [ -z "$val" ]; then
        val=$(n1_config_val ".${key}" "$(n1_plugin_root)/defaults/queue.json")
    fi
    printf '%s' "$val"
}

n1_story_parse_service() {
    # Usage: n1_story_parse_service <title>
    # Prints the service tag from "<service> | <title>" or nothing.
    local title="$1"
    case "$title" in
        *" |"*) printf '%s' "${title%% |*}" | sed 's/[[:space:]]*$//' ;;
        *) printf '' ;;
    esac
}

n1_story_find_repo() {
    # Usage: n1_story_find_repo <service> [n1_root]
    # Prints "<config-path>\t<repoPath>" for the first ~/.n1/*/config.json whose
    # ticketTagging.service matches case-insensitively. Exit 1 when none match.
    local service="$1" root="${2:-$HOME/.n1}"
    local want; want=$(printf '%s' "$service" | tr '[:upper:]' '[:lower:]')
    local cfg svc repo
    for cfg in "$root"/*/config.json; do
        [ -f "$cfg" ] || continue
        svc=$(jq -r '.ticketTagging.service // empty' "$cfg" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        [ -n "$svc" ] && [ "$svc" = "$want" ] || continue
        repo=$(jq -r '.repoPath // empty' "$cfg" 2>/dev/null)
        printf '%s\t%s' "$cfg" "$repo"
        return 0
    done
    return 1
}

_n1_story_size_rank() {
    case "$1" in
        XS) echo 1 ;; S) echo 2 ;; M) echo 3 ;; L) echo 4 ;; XL) echo 5 ;;
        *) echo 2 ;;  # unknown/empty counts as S
    esac
}

n1_story_pick_model() {
    # Usage: n1_story_pick_model <size> [flags-csv]
    # sonnet by default; opus when size >= queue.opusFromSize or a risk flag is set.
    local size="$1" flags="${2:-}" threshold
    threshold=$(n1_queue_val opusFromSize)
    local f
    local -a _flags
    IFS=',' read -r -a _flags <<< "$flags"
    for f in "${_flags[@]+"${_flags[@]}"}"; do
        case "$f" in
            security|public-api|schema-migration|contract) printf 'opus'; return ;;
        esac
    done
    if [ "$(_n1_story_size_rank "$size")" -ge "$(_n1_story_size_rank "${threshold:-M}")" ]; then
        printf 'opus'
    else
        printf 'sonnet'
    fi
}

n1_story_match_clarification() {
    # Usage: n1_story_match_clarification <question_text> <story_md_path>
    # Searches ## Clarifications in story.md for a Q whose words overlap >= 60% with question_text.
    # Prints the answer text if matched, empty string otherwise. Returns 0 in both cases.
    local question="$1" story_path="$2"
    [ -f "$story_path" ] || return 0

    local in_section=0
    local current_q="" current_a=""
    while IFS= read -r line; do
        case "$line" in
            "## Clarifications"*) in_section=1; continue ;;
            "## "*) [ "$in_section" = "1" ] && break ;;
        esac
        [ "$in_section" = "1" ] || continue

        if [[ "$line" =~ ^[[:space:]]*\*\*Q:\*\*[[:space:]]*(.*) ]]; then
            if [ -n "$current_q" ] && [ -n "$current_a" ]; then
                if _n1_word_overlap "$question" "$current_q" 60; then
                    printf '%s' "$current_a"
                    return 0
                fi
            fi
            current_q="${BASH_REMATCH[1]}"
            current_a=""
        elif [[ "$line" =~ ^[[:space:]]*\*\*A:\*\*[[:space:]]*(.*) ]]; then
            current_a="${BASH_REMATCH[1]}"
        fi
    done < "$story_path"

    if [ -n "$current_q" ] && [ -n "$current_a" ]; then
        if _n1_word_overlap "$question" "$current_q" 60; then
            printf '%s' "$current_a"
            return 0
        fi
    fi
}

_n1_word_overlap() {
    local a="$1" b="$2" threshold="$3"
    awk -v a="$a" -v b="$b" -v threshold="$threshold" '
    BEGIN {
        na = split(tolower(a), wa, /[^a-zA-Z0-9]+/)
        nb = split(tolower(b), wb, /[^a-zA-Z0-9]+/)
        for (i = 1; i <= nb; i++) words_b[wb[i]] = 1
        overlap = 0
        total_a = 0
        for (i = 1; i <= na; i++) {
            if (wa[i] != "") {
                total_a++
                if (wa[i] in words_b) overlap++
            }
        }
        if (total_a == 0) exit 1
        pct = int(overlap * 100 / total_a)
        exit (pct >= threshold) ? 0 : 1
    }'
}

n1_queue_child_status() {
    # Usage: n1_queue_child_status <overview.md> <exit-code>
    # Prints: pr | escalated | failed | running
    local overview="$1" exit_code="${2:-0}"
    if [ ! -f "$overview" ]; then
        [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
        return
    fi
    local step; step=$(n1_read_frontmatter "$overview" "step")
    # pr/ci/done all mean stop-at-CI success
    case "$step" in pr|ci|done) printf 'pr'; return ;; esac
    if [ "$step" = "escalated" ] || awk '/^## Escalations/{f=1;next} /^## /{f=0} f && NF' "$overview" | grep -q .; then
        printf 'escalated'; return
    fi
    [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
}

n1_queue_child_pr_url() {
    # Usage: n1_queue_child_pr_url <overview.md> — pr_url from Pending/Finish blocks.
    local overview="$1"
    [ -f "$overview" ] || return 0
    awk '/^## (Pending|Finish)/{f=1;next} /^## /{f=0} f && /^pr_url:/{sub(/^pr_url:[[:space:]]*/,""); print; exit}' "$overview"
}

n1_queue_child_cmd() {
    # Usage: n1_queue_child_cmd <repoPath> <ticket-id> <model> <run-id> <log-path>
    # Like n1_story_child_cmd but with queue-specific env vars.
    # Test hook: when N1_QUEUE_CHILD_STUB is set, the command is "$N1_QUEUE_CHILD_STUB" <ticket> <overview-path>.
    local repo="$1" id="$2" model="$3" run_id="$4" log="$5"
    if [ -n "${N1_QUEUE_CHILD_STUB:-}" ]; then
        printf '"%s" "%s"' "$N1_QUEUE_CHILD_STUB" "$id"
        return
    fi
    printf 'cd "%s" && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STOP_AT=ci N1_QUEUE_RUN_ID="%s" %s' \
        "$repo" "$run_id" "$(n1_headless_cmd n1-start "$id" "$model" "$log")"
}

n1_queue_row_status() {
    # Usage: n1_queue_row_status <queue.md> <row-number> <status> [reason]
    # Rewrites the Status (and optionally Reason) cell of the Plan table row
    # whose first cell equals <row-number>.
    # Row shape: | # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
    local file="$1" row_num="$2" status="$3" reason="${4:-}"
    awk -v num="$row_num" -v st="$status" -v rsn="$reason" 'BEGIN { FS="|"; OFS="|" } {
        f2 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
        if (f2 == num && NF >= 9) {
            $8 = " " st " "
            if (rsn != "") $9 = " " rsn " "
        }
        print
    }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

n1_queue_pending_rows() {
    # Usage: n1_queue_pending_rows <queue.md>
    # Prints: #<TAB>Ticket<TAB>Repo<TAB>N1 Home<TAB>Model for rows with Status "pending".
    local file="$1"
    awk -F'|' '
    {
        for (i = 1; i <= NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        }
        if ($8 == "pending" && $2 ~ /^[0-9]+$/) {
            printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $5, $6, $7
        }
    }' "$file"
}

n1_queue_decision_counts() {
    # Usage: n1_queue_decision_counts <queue.md>
    # Prints: plan_decisions<TAB>autonomous_decisions<TAB>escalations
    # plan_decisions  = Decision Ledger rows matching "^| preview | edit |"
    # autonomous_decisions = sum of "^| [^|]* | headless |" lines in each non-pending/skip/done-before-run ticket's overview.md
    # escalations     = Plan rows with Status "escalated"
    local file="$1"
    local plan_decisions; plan_decisions=$(grep -c '^| preview | edit |' "$file" 2>/dev/null || true)
    local auto_decisions=0 escalations=0
    while IFS=$'\t' read -r ticket n1home status; do
        case "$status" in pending|skip|done-before-run) continue ;; esac
        [ "$status" = "escalated" ] && escalations=$((escalations+1))
        local overview="$n1home/memory/$ticket/overview.md"
        if [ -f "$overview" ]; then
            local cnt; cnt=$(grep -c '^| [^|]* | headless |' "$overview" 2>/dev/null || true)
            auto_decisions=$((auto_decisions+cnt))
        fi
    done < <(awk -F'|' '{for(i=1;i<=NF;i++) gsub(/^[[:space:]]+|[[:space:]]+$/,"",$i); if($2~/^[0-9]+$/ && NF>=9) printf "%s\t%s\t%s\n",$3,$6,$8}' "$file")
    printf '%s\t%s\t%s\n' "$plan_decisions" "$auto_decisions" "$escalations"
}

