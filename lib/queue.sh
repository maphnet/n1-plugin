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
    # Usage: n1_queue_child_cmd <repoPath> <ticket-id> <model> <run-id> <log-path> [session-name]
    # codex: synchronous headless child writing <log-path>.
    # claude-code: background-session launch named <session-name>; stdout carries the
    # session id (see n1_queue_parse_launch). <log-path> is unused there.
    # Test hook: when N1_QUEUE_CHILD_STUB is set, the command is "$N1_QUEUE_CHILD_STUB" <ticket>.
    local repo="$1" id="$2" model="$3" run_id="$4" log="$5" name="${6:-}"
    if [ -n "${N1_QUEUE_CHILD_STUB:-}" ]; then
        printf '"%s" "%s"' "$N1_QUEUE_CHILD_STUB" "$id"
        return
    fi
    if [ "$(n1_host)" = claude-code ]; then
        local settings
        settings=$(jq -cn --arg run "$run_id" --arg parent "$(n1_session_id)" \
            '{env:{N1_HEADLESS:"1",N1_AUTONOMY_PRESET:"autonomous",N1_STOP_AT:"ci",N1_QUEUE_RUN_ID:$run,N1_HOST:"claude-code",N1_PARENT_SESSION_ID:$parent},worktree:{bgIsolation:"none"}}')
        n1_bg_launch_cmd "$name" n1-start "$id" "$model" "$repo" "$settings"
        return
    fi
    printf 'cd %q && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STOP_AT=ci N1_QUEUE_RUN_ID="%s" %s' \
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
    # Usage: n1_queue_pending_rows <queue.md> [status-regex]
    # Prints: #<TAB>Ticket<TAB>Repo<TAB>N1 Home<TAB>Model<TAB>Status for Plan rows whose
    # Status matches <status-regex> (anchored; default "pending").
    local file="$1" re="${2:-pending}"
    awk -F'|' -v re="$re" '
    {
        for (i = 1; i <= NF; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        }
        if ($8 ~ ("^(" re ")$") && $2 ~ /^[0-9]+$/) {
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $5, $6, $7, $8
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

n1_queue_parse_launch() {
    # Usage: n1_queue_parse_launch <launch-output>
    # Prints the session id from "backgrounded · <id> · <name>" (exit 0). Otherwise prints a
    # failure reason (exit 1): bypass-permissions-disclaimer when the output asks for the
    # one-time interactive consent, bg-launch-failed for anything else.
    local id
    id=$(printf '%s\n' "$1" | sed -n 's/.*backgrounded[^0-9a-f]*\([0-9a-f]\{8\}\).*/\1/p' | head -1)
    if [ -n "$id" ]; then printf '%s' "$id"; return 0; fi
    # ponytail: consent detection is a keyword match; tighten once a real refusal message is captured.
    if printf '%s' "$1" | grep -qiE 'dangerously-skip-permissions|disclaimer'; then
        printf 'bypass-permissions-disclaimer'
    else
        printf 'bg-launch-failed'
    fi
    return 1
}

n1_queue_bg_state() {
    # Usage: n1_queue_bg_state <agents-json> <session-id>
    # Prints working | blocked | done | missing | failed for the background session launched
    # with that id (the short 8-hex id from launch, matched against .id or a .sessionId prefix;
    # restricted to objects that carry .state, since interactive sessions have neither). Names
    # are reused across runs (queue.md rows restart numbering each run), so matching by id —
    # not name — is required to avoid picking up a stale session from an earlier run. missing
    # (not listed yet, e.g. supervisor lag right after launch) is reported as-is; callers treat
    # it as working until a grace count of consecutive misses runs out. An empty/malformed
    # session id (never a valid 8-hex launch id) never reaches the jq lookup — it would match
    # any session via startswith("") — and fails immediately. failed, stopped and any other
    # state map to failed.
    local sid="$2" st
    case "$sid" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
        *) printf 'failed'; return ;;
    esac
    st=$(printf '%s' "$1" | jq -r --arg sid "$sid" \
        '[.. | objects | select(has("state")) | select(.id == $sid or ((.sessionId // "") | startswith($sid)))][0].state // "missing"' 2>/dev/null)
    case "$st" in
        working|blocked|done|missing) printf '%s' "$st" ;;
        *) printf 'failed' ;;
    esac
}

n1_queue_session_id() {
    # Usage: n1_queue_session_id <queue.md> <ticket> — Session cell of the ticket's last Runs row.
    awk -F'|' -v tk="$2" '
        /^## Runs/ { f = 1; next }
        f {
            t = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            if (t == tk) { s = $7; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); id = s }
        }
        END { print id }' "$1"
}

n1_queue_awaiting_hints() {
    # Usage: n1_queue_awaiting_hints <queue.md>
    # Prints "<ticket>: <resume command>" for each Plan row waiting on a human answer.
    local file="$1" t sid
    while IFS=$'\t' read -r _ t _ _ _ _; do
        sid=$(n1_queue_session_id "$file" "$t")
        if [ -n "$sid" ]; then printf '%s: %s\n' "$t" "$(n1_bg_cmd attach "$sid")"; fi
    done < <(n1_queue_pending_rows "$file" 'awaiting-human')
}

