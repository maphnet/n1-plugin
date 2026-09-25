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
    if [ "$step" = "escalated" ] || [ -n "$(n1_queue_escalation_text "$overview")" ]; then
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
    # Caller env N1_QUEUE_TAG (tag mode only, else empty) is forwarded so the child can
    # release the queue tag on handoff (NP-199).
    # Test hook: when N1_QUEUE_CHILD_STUB is set, the command is "$N1_QUEUE_CHILD_STUB" <ticket>.
    local repo="$1" id="$2" model="$3" run_id="$4" log="$5" name="${6:-}"
    if [ -n "${N1_QUEUE_CHILD_STUB:-}" ]; then
        printf '"%s" "%s"' "$N1_QUEUE_CHILD_STUB" "$id"
        return
    fi
    if [ "$(n1_host)" = claude-code ]; then
        local settings
        settings=$(jq -cn --arg run "$run_id" --arg parent "$(n1_session_id)" --arg tag "${N1_QUEUE_TAG:-}" \
            '{env:{N1_HEADLESS:"1",N1_AUTONOMY_PRESET:"autonomous",N1_STOP_AT:"ci",N1_QUEUE_RUN_ID:$run,N1_QUEUE_TAG:$tag,N1_HOST:"claude-code",N1_PARENT_SESSION_ID:$parent,N1_UNATTENDED:"ask"},worktree:{bgIsolation:"none"}}')
        n1_bg_launch_cmd "$name" n1-start "$id" "$model" "$repo" "$settings"
        return
    fi
    printf 'cd %q && N1_HEADLESS=1 N1_AUTONOMY_PRESET=autonomous N1_STOP_AT=ci N1_QUEUE_RUN_ID="%s" N1_QUEUE_TAG=%q %s' \
        "$repo" "$run_id" "${N1_QUEUE_TAG:-}" "$(n1_headless_cmd n1-start "$id" "$model" "$log")"
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

n1_queue_already_run() {
    # Usage: n1_queue_already_run <overview.md>
    # Exit 0 and print the stamped queue_run_id when a previous queue run handled this
    # ticket and did not confirm the tag release (stale tag -> exclude from intake).
    # Exit 1 when never queued, or when the tag was released and a human re-added it.
    local ov="$1" run
    run=$(n1_read_frontmatter "$ov" queue_run_id)
    [ -n "$run" ] || return 1
    [ "$(n1_read_frontmatter "$ov" queue_tag_removed)" = true ] && return 1
    printf '%s' "$run"
}

n1_queue_release_rows() {
    # Usage: n1_queue_release_rows <queue.md>
    # Prints unique "<ticket>\t<n1-home>" for tag-mode Plan rows with a handoff outcome
    # (pr, escalated, failed) whose overview.md lacks queue_tag_removed: true.
    local q="$1" t h
    [ "$(n1_read_frontmatter "$q" mode)" = tag ] || return 0
    n1_queue_pending_rows "$q" 'pr|escalated|failed' | cut -f2,4 | sort -u |
        while IFS=$'\t' read -r t h; do
            [ "$(n1_read_frontmatter "$h/memory/$t/overview.md" queue_tag_removed)" = true ] ||
                printf '%s\t%s\n' "$t" "$h"
        done
}

n1_queue_release_cmd() {
    # Usage: n1_queue_release_cmd <queue_id> <repo> <log-path>
    # Automatic tag-release backstop (NP-199 CCR fix): report.md's release wiring
    # only runs on --status/--watch, which nothing guarantees a human will trigger
    # after a queue run. The runner (scripts/n1-queue-run.sh) calls this to fire a
    # fresh headless "/n1:n1-queue --status <queue_id>" re-invocation, so the report
    # step's release-tag section runs unattended too.
    # Test hook: when N1_QUEUE_RELEASE_STUB is set, the command is
    # "$N1_QUEUE_RELEASE_STUB" <queue_id>.
    local id="$1" repo="$2" log="$3"
    if [ -n "${N1_QUEUE_RELEASE_STUB:-}" ]; then
        printf '"%s" "%s"' "$N1_QUEUE_RELEASE_STUB" "$id"
        return
    fi
    n1_headless_cmd n1-queue "--status $id" sonnet "$log" "$repo"
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

n1_queue_event() {
    # Usage: n1_queue_event <events.jsonl> <queue_id> <run_id> <event> [key=value]...
    # Appends one JSON line. Every line carries the same 10 keys (ts, queue, run_id, event,
    # ticket, outcome, pr, session, duration_s, reason); absent ones are "" (duration_s: null).
    # Best-effort: never fails the caller.
    local file="$1" q="$2" run="$3" ev="$4" kv; shift 4
    local -a args=()
    for kv in "$@"; do args+=(--arg "${kv%%=*}" "${kv#*=}"); done
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg queue "$q" --arg run_id "$run" --arg event "$ev" \
        ${args[@]+"${args[@]}"} \
        '$ARGS.named | {ts, queue, run_id, event,
            ticket: (.ticket // ""), outcome: (.outcome // ""), pr: (.pr // ""), session: (.session // ""),
            duration_s: ((.duration_s // "") | (tonumber? // null)), reason: (.reason // "")}' \
        >> "$file" 2>/dev/null || true
    return 0
}

n1_queue_escalation_text() {
    # Usage: n1_queue_escalation_text <overview.md> — first "## Escalations" entry, or empty.
    [ -f "$1" ] || return 0
    awk '/^## Escalations/{f=1;next} /^## /{f=0} f && NF {sub(/^[-*][[:space:]]*/,""); print; exit}' "$1"
}


n1_queue_digest() {
    # Usage: n1_queue_digest <n1-home> — one status line for the queue active in the last 24h,
    # preferring one with a ticket that needs you; prints nothing when none qualifies.
    # Reads only <n1-home>/queue/*/events.jsonl (latest run per queue, latest event per ticket);
    # non-JSON lines are skipped.
    local f
    for f in "$1"/queue/*/events.jsonl; do [ -f "$f" ] && cat "$f"; done 2>/dev/null | jq -nrR '
        [inputs | fromjson? | objects] | group_by(.queue) | map(
            .[-1] as $end
            | ([.[] | select(.run_id == $end.run_id and .ticket != "")] | group_by(.ticket) | map(.[-1])) as $t
            | ([$t[] | select(.event == "escalated" or .outcome == "escalated") | .ticket]) as $needs
            | ([$t[] | select(.event == "ticket_finished" and .outcome == "pr")] | length) as $pr
            | ([$t[] | select(.event == "ticket_finished" and .outcome == "failed")] | length) as $failed
            | ([$t[] | select(.event == "ticket_started" or .event == "unblocked") | .ticket]) as $running
            | {needs: ($needs | length), ts: $end.ts,
               line: ("Queue \($end.queue): " + ([
                   (if $pr > 0 then "\($pr) PR" else empty end),
                   (if ($needs | length) > 0 then "\($needs | length) needs you (\($needs | join(", ")))" else empty end),
                   (if $failed > 0 then "\($failed) failed" else empty end),
                   (if ($running | length) > 0 then "running \($running | join(", "))" else empty end),
                   (if $end.event == "queue_done" then "done" elif $end.event == "halted" then "halted" else empty end)
               ] | if length == 0 then ["started"] else . end | join(", ")))})
        | map(select(.ts >= (now - 86400 | todate)))
        | sort_by([(.needs > 0), .ts]) | last | .line // empty' 2>/dev/null
    return 0
}

n1_queue_watch() {
    # Usage: n1_queue_watch <queue_dir> <run_id> <runner_pid> [from_line]
    # Session-side relay for one queue run. Every queue.pollSeconds, prints one line per new
    # escalated / ticket_finished / halted / queue_done event in <queue_dir>/events.jsonl whose
    # run_id is <run_id> (never queue id alone: a relaunch appends to the same file).
    # Consumed-line count persists in <queue_dir>/.watch-<run_id>.<session>, so re-running the
    # identical command after a host timeout resumes with no gap and no replay. Without that
    # cursor it starts at line <from_line> (default: current end of file).
    # Final lines end with "Watch ended.": on halted, queue_done, or runner pid gone; the
    # cursor is removed and it returns 0. Otherwise it polls until killed.
    # ponytail: a watch killed with its session leaves its small cursor file behind; sweep if they pile up.
    local dir="$1" run="$2" pid="$3" from="${4:-}" events="$1/events.jsonl" q sid cursor seen total alive poll
    local ev t out pr s reason
    q="${dir##*/}"
    sid=$(n1_session_id); sid="${sid:-nosession}"
    case "$run$sid" in ''|*[!a-zA-Z0-9_-]*) echo "n1-queue: bad run or session id" >&2; return 1 ;; esac
    case "$pid" in ''|*[!0-9]*) echo "n1-queue: bad runner pid" >&2; return 1 ;; esac
    cursor="$dir/.watch-$run.$sid"
    if [ -f "$cursor" ]; then seen=$(cat "$cursor")
    elif [ -n "$from" ]; then seen="$from"
    elif [ -f "$events" ]; then seen=$(wc -l < "$events")
    else seen=0; fi
    seen="${seen//[[:space:]]/}"; case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    poll=$(n1_queue_val pollSeconds)
    while true; do
        # Liveness is sampled before reading, so events written just before the runner exits are relayed first.
        # ponytail: kill -0 can't tell a recycled pid from the runner; compare /proc start time if that bites.
        alive=0; kill -0 "$pid" 2>/dev/null && alive=1
        total=0; [ -f "$events" ] && total=$(wc -l < "$events"); total="${total//[[:space:]]/}"
        if [ "$total" -gt "$seen" ]; then
            while IFS=$'\x1f' read -r ev t out pr s reason; do
                case "$ev" in
                    escalated)
                        printf 'n1-queue %s: %s needs you: %s%s\n' "$q" "$t" "${reason:-waiting for an answer}" \
                            "${s:+ (resume: $(n1_bg_cmd attach "$s"))}" ;;
                    ticket_finished)
                        printf 'n1-queue %s: %s finished: %s%s%s\n' "$q" "$t" "$out" "${pr:+ $pr}" "${reason:+ ($reason)}" ;;
                    halted|queue_done)
                        [ "$ev" = halted ] && ev=halted || ev=finished
                        printf 'n1-queue %s: %s%s. Watch ended.\n' "$q" "$ev" "${reason:+: $reason}"
                        rm -f "$cursor"; return 0 ;;
                esac
            done < <(sed -n "$((seen + 1)),${total}p" "$events" | jq -rR --arg run "$run" '
                fromjson? | objects | select(.run_id == $run)
                | select(.event == "escalated" or .event == "ticket_finished" or .event == "halted" or .event == "queue_done")
                | [.event, .ticket, .outcome, .pr, .session, .reason]
                | map(tostring | gsub("[\u0000-\u001f\u007f]"; " ") | .[:300]) | join("\u001f")' 2>/dev/null)
            seen="$total"
        fi
        if [ "$alive" = 0 ]; then
            printf 'n1-queue %s: runner (pid %s) is gone without a finish or halt event. Watch ended.\n' "$q" "$pid"
            rm -f "$cursor"; return 0
        fi
        printf '%s\n' "$seen" > "$cursor" 2>/dev/null
        sleep "${poll:-30}"
    done
}

n1_fmt_elapsed() {
    # Usage: n1_fmt_elapsed <seconds> — "<1m" | "Nm" | "NhMm". Empty/non-numeric prints nothing.
    local s="$1"
    case "$s" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$s" -lt 60 ]; then
        printf '<1m'
    elif [ "$s" -lt 3600 ]; then
        printf '%dm' "$((s / 60))"
    else
        printf '%dh%dm' "$((s / 3600))" "$(((s % 3600) / 60))"
    fi
}

n1_queue_status_table() {
    # Usage: n1_queue_status_table <queue.md> <events.jsonl>
    # Prints one tab-separated row per Plan row: Ticket State Step Elapsed Cost PR Attach.
    # On claude-code, live-overrides State for in-progress/awaiting-human rows from
    # `claude agents --json --all` via n1_queue_bg_state (same missing/failed degradation
    # it already applies; no second failure path). On codex, Plan Status + events.jsonl are
    # already the full state (children run synchronously, one at a time).
    local file="$1" events="$2" host agents_json now
    host=$(n1_read_frontmatter "$file" host)
    [ -n "$host" ] || host=$(n1_host)
    if [ "$host" = claude-code ]; then
        agents_json=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null)
    fi
    now=$(date +%s)

    while IFS=$'\t' read -r num ticket repo n1h model status; do
        local state="$status" step="" elapsed="" cost="—" pr="" attach="" sid
        case "$status" in
            in-progress|awaiting-human)
                sid=$(n1_queue_session_id "$file" "$ticket")
                if [ "$host" = claude-code ] && [ -n "$sid" ]; then
                    local bgs; bgs=$(n1_queue_bg_state "$agents_json" "$sid")
                    case "$bgs" in
                        working) state=in-progress ;;
                        blocked) state=awaiting-human ;;
                        missing|failed) state="$bgs" ;;
                        done) : ;;  # runner hasn't finalized yet; keep the Plan status as-is
                    esac
                fi
                step=$(n1_read_frontmatter "$n1h/memory/$ticket/overview.md" step)
                local started; started=$(n1_queue_session_started "$file" "$ticket")
                if [ -n "$started" ]; then
                    local started_epoch
                    started_epoch=$(date -u -d "$started" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
                    [ "$started_epoch" -gt 0 ] && elapsed=$(n1_fmt_elapsed "$((now - started_epoch))")
                fi
                [ "$state" = awaiting-human ] && [ -n "$sid" ] && [ "$host" = claude-code ] && attach=$(n1_bg_cmd attach "$sid")
                ;;
            pr|failed|deferred|escalated)
                local dur; dur=$(_n1_queue_event_duration "$events" "$ticket")
                [ -n "$dur" ] && elapsed=$(n1_fmt_elapsed "$dur")
                if [ "$status" = pr ]; then
                    pr=$(n1_queue_child_pr_url "$n1h/memory/$ticket/overview.md")
                    [ -n "$pr" ] || pr=$(_n1_queue_run_pr "$file" "$ticket")
                else
                    step=$(n1_read_frontmatter "$n1h/memory/$ticket/overview.md" step)
                    [ "$step" = escalated ] && step=$(_n1_queue_escalated_step "$n1h/memory/$ticket/overview.md")
                fi
                ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ticket" "$state" "$step" "$elapsed" "$cost" "$pr" "$attach"
    done < <(awk -F'|' '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) } $2 ~ /^[0-9]+$/ && NF >= 9 { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $5, $6, $7, $8 }' "$file")
}

_n1_queue_escalated_step() {
    # Usage: _n1_queue_escalated_step <overview.md> — step name from the last
    # "- [headless] <step>: ..." line in the ## Escalations section, falling
    # back to "escalated" when none is found (frontmatter step is overwritten
    # to "escalated" by the headless escalation, losing the original step).
    local file="$1" step
    [ -f "$file" ] || { echo escalated; return 0; }
    step=$(awk '
        /^## Escalations/ { f = 1; next }
        /^## / { f = 0 }
        f && /^- \[headless\] [^:]+:/ {
            line = $0
            sub(/^- \[headless\] /, "", line)
            sub(/:.*/, "", line)
            last = line
        }
        END { print last }' "$file")
    [ -n "$step" ] && echo "$step" || echo escalated
}

_n1_queue_run_pr() {
    # Usage: _n1_queue_run_pr <queue.md> <ticket> — PR cell of the ticket's last Runs row.
    awk -F'|' -v tk="$2" '
        /^## Runs/ { f = 1; next }
        f {
            t = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            if (t == tk) { p = $6; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p); pr = p }
        }
        END { print pr }' "$1"
}

_n1_queue_event_duration() {
    # Usage: _n1_queue_event_duration <events.jsonl> <ticket> — last ticket_finished duration_s.
    local file="$1" ticket="$2"
    [ -f "$file" ] || return 0
    jq -nr --arg t "$ticket" '[inputs | objects | select(.event == "ticket_finished" and .ticket == $t) | .duration_s // empty] | last // empty' "$file" 2>/dev/null
}

n1_queue_session_started() {
    # Usage: n1_queue_session_started <queue.md> <ticket> — Started cell of the ticket's last Runs row.
    awk -F'|' -v tk="$2" '
        /^## Runs/ { f = 1; next }
        f {
            t = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            if (t == tk) { s = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); ts = s }
        }
        END { print ts }' "$1"
}

n1_notify() {
    # Usage: n1_notify <needs-you|done|info> <text> — best-effort out-of-session alert.
    # Backend from queue.notify: desktop (default) | ntfy (queue.ntfyTopic) | command
    # (queue.notifyCommand gets {"ts","kind","text"} on stdin) | none. Never fails the caller.
    local kind="$1" text="$2" title="N1 queue: $1" backend val
    backend=$(n1_queue_val notify)
    case "${backend:-desktop}" in
        none) ;;
        command)
            val=$(n1_queue_val notifyCommand)
            [ -z "$val" ] || jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg kind "$kind" --arg text "$text" \
                '{ts:$ts,kind:$kind,text:$text}' 2>/dev/null | timeout 10 bash -c "$val" >/dev/null 2>&1 ;;
        ntfy)
            val=$(n1_queue_val ntfyTopic)
            case "$val" in ""|*://*) ;; *) val="https://ntfy.sh/$val" ;; esac
            [ -z "$val" ] || timeout 10 curl -fsS -H "Title: $title" \
                -H "Priority: $([ "$kind" = needs-you ] && echo high || echo default)" \
                -d "$text" "$val" >/dev/null 2>&1 ;;
        *)
            n1_desktop_notify "$title" "$text" \
                || echo "n1_notify: no desktop notifier available; skipped ($kind: $text)" >&2 ;;
    esac
    return 0
}
