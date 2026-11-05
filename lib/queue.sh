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
    # Usage: n1_queue_child_status <overview.md> <exit-code> [strict]
    # Prints: pr | escalated | failed | running — pr needs pr_url at step pr (N1-53)
    # strict=1 (NP-216 live-poll callers): only step:escalated counts as escalated.
    # ## Escalations is an append-only log (lib/memory.sh) that also gets an entry
    # in ask-mode while the child continues past the question — its mere presence
    # is not proof of a terminal escalation for a still-running child. The bg-poll
    # caller passes strict=1 to require step:escalated, not just the text's presence.
    local overview="$1" exit_code="${2:-0}" strict="${3:-}"
    if [ ! -f "$overview" ]; then
        [ "$exit_code" != "0" ] && printf 'failed' || printf 'running'
        return
    fi
    local step; step=$(n1_read_frontmatter "$overview" "step")
    # ci/done mean stop-at-CI success. skills/n1-pr/steps/02-push-create.md Step 6 sets
    # frontmatter step:pr and records pr_url in the same instruction, but as two separate,
    # non-atomic writes (N1-53): a live/bg-poll read of overview.md landing between them sees
    # step:pr with no pr_url yet. Terminal only once pr_url is actually recorded.
    case "$step" in
        ci|done) printf 'pr'; return ;;
        pr) if [ -n "$(n1_queue_child_pr_url "$overview")" ]; then printf 'pr'; return; fi ;;
    esac
    if [ "$step" = "escalated" ] || { [ "$strict" != "1" ] && [ -n "$(n1_queue_escalation_text "$overview")" ]; }; then
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

n1_queue_child_open_pr() {
    # Usage: n1_queue_child_open_pr <ticket> <n1-home> <repo-path> [start-epoch] — URL of an open PR for the
    # child's run branch, or nothing (N1-182). Called only when a bg child ended without
    # recording pr_url (off-script child), never on hot polls. Branch: "branch" of the newest
    # telemetry envelope (the child's own run), then the ticket id. Only a same-repo PR (not a
    # fork PR on a guessable branch name) whose headRefOid equals the local tip of that branch
    # counts, so a stale PR from an earlier run does not. With start-epoch, an envelope file older
    # than the child's launch belongs to an earlier run: print nothing. Fail open: errors print nothing.
    local t="$1" h="$2" repo="$3" start="${4:-}" b url oid tip out seen="" newest
    [ -d "$repo" ] || return 0
    newest=$(ls -t "$h/memory/$t/telemetry/raw/steps/"*.jsonl 2>/dev/null | head -1)
    if [ -n "$newest" ] && [[ "$start" =~ ^[0-9]+$ ]] && [ "$(stat -c %Y "$newest" 2>/dev/null || echo 0)" -lt "$start" ]; then
        return 0
    fi
    for b in "$([ -n "$newest" ] && grep -o '"layer":"envelope"[^}]*"branch":"[^"]*"' "$newest" 2>/dev/null | sed 's/.*"branch":"//; s/"$//' | tail -1)" "$t"; do
        [[ "$b" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]] && [ "$b" != "$seen" ] || continue
        seen="$b"
        out=$(cd "$repo" && timeout 10 gh pr list --head "$b" --state open --json url,headRefOid,isCrossRepository -q '[.[] | select(.isCrossRepository | not)][0] | select(.) | [.url, .headRefOid] | @tsv' </dev/null 2>/dev/null)
        IFS=$'\t' read -r url oid <<< "$out"
        tip=$(git -C "$repo" rev-parse --verify -q "refs/heads/$b" 2>/dev/null)
        if [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]] && [ -n "$tip" ] && [ "$oid" = "$tip" ]; then
            printf '%s' "$url"; return 0
        fi
    done
    return 0
}

_n1_queue_bg_settings() {
    # Usage: _n1_queue_bg_settings <run-id> — --settings JSON shared by queue children and the runner's
    # chained n1-finish sessions (N1-185), so both run as unattended queue runs (fullAuto required).
    # N1-291: caller env N1_STORY_ID/N1_STORY_BRANCH (story-mode child launch only) are appended when the branch is set.
    jq -cn --arg run "$1" --arg parent "$(n1_session_id)" --arg tag "${N1_QUEUE_TAG:-}" --arg dir "${N1_QUEUE_DIR:-}" \
        --arg sid "${N1_STORY_ID:-}" --arg sb "${N1_STORY_BRANCH:-}" \
        '{env:({N1_HEADLESS:"1",N1_AUTONOMY_PRESET:"autonomous",N1_QUEUE_RUN_ID:$run,N1_QUEUE_TAG:$tag,N1_QUEUE_DIR:$dir,N1_PARENT_SESSION_ID:$parent,N1_UNATTENDED:"ask"} + (if $sb == "" then {} else {N1_STORY_ID:$sid,N1_STORY_BRANCH:$sb} end)),worktree:{bgIsolation:"none"}}'
}

n1_queue_child_cmd() {
    # Usage: n1_queue_child_cmd <repoPath> <ticket-id> <model> <run-id> <log-path> [session-name]
    # Background-session launch named <session-name>; stdout carries the session id
    # (see n1_queue_parse_launch). <log-path> is unused but kept for call-shape compatibility.
    # Caller env N1_QUEUE_TAG (tag mode only, else empty) is forwarded so the child can
    # release the queue tag on handoff (NP-199). Caller env N1_QUEUE_DIR (always set by the
    # runner) is forwarded so the child can read its ## Decisions row (NP-203).
    local repo="$1" id="$2" model="$3" run_id="$4" name="${6:-}"
    n1_bg_launch_cmd "$name" n1-start "$id" "$model" "$repo" "$(_n1_queue_bg_settings "$run_id")"
}

n1_queue_finish_cmd() {
    # Usage: n1_queue_finish_cmd <repoPath> <ticket-id> <model> <run-id> <session-name>
    # N1-185: background `n1-finish <ticket> chained` for the runner's fullAuto chain. Same settings env
    # as a child, so n1-finish re-checks n1_merge_authorized as an unattended run and the merge-deny
    # hook still applies. The runner itself never merges.
    n1_bg_launch_cmd "$5" n1-finish "$2 chained" "$3" "$1" "$(_n1_queue_bg_settings "$4")"
}

n1_queue_clean_cmd() {
    # Usage: n1_queue_clean_cmd <repoPath> <ticket-id> <model> <run-id> <session-name>
    # N1-339: background `n1-clean --ticket <ticket>` for a merged row, same settings env as a chained finish.
    # The runner never removes a worktree itself.
    n1_bg_launch_cmd "$5" n1-clean "--ticket $2" "$3" "$1" "$(_n1_queue_bg_settings "$4")"
}

n1_queue_cleanup_needed() {
    # Usage: n1_queue_cleanup_needed <overview.md> - N1-339: exit 0 (launch a clean) unless the overview's Cleanup
    # line already shows the branch deleted or absent (finish cleaned it).
    ! grep -qE '^- \*\*Cleanup:\*\* .*branch:(deleted|none)' "$1" 2>/dev/null
}

n1_queue_pr_state() {
    # Usage: n1_queue_pr_state <pr-url> — N1-185: OPEN/MERGED/CLOSED for a GitHub PR URL. Prints
    # nothing for any other URL (SEC-2 shape, as in n1_queue_held_sweep) or on a gh error; callers
    # fail open to the plain pr stop.
    [[ "$1" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]] || return 0
    # N1-214: a transient gh failure or empty read is retried (3 attempts, 2s/4s backoff) before
    # giving up, so one flaky read does not strand a merged PR as pr-state-unreadable.
    local attempt out
    for attempt in 1 2 3; do
        out=$(timeout 30 gh pr view --json state -q .state -- "$1" </dev/null 2>/dev/null) || out=""
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
        [ "$attempt" -lt 3 ] && sleep $((attempt * 2))
    done
    return 0
}

_n1_queue_sanitize_cell() {
    # Usage: _n1_queue_sanitize_cell <text>
    # Strips `|` and backslashes, turns newlines/tabs into spaces, so untrusted text (a ticket title, tracker
    # status/reason, or plan-time free text) can never forge a table cell or spill into an
    # adjacent Decisions row (NP-203 SEC-2/CR-2), and can never survive as a `\n`/`\174`-style
    # escape an awk -v assignment would later re-expand into a literal newline or `|` (SEC-3,
    # defense in depth alongside the ENVIRON[]-based awk callers below).
    printf '%s' "$1" | tr '\n\t' '  ' | tr -d '|\\'
}

n1_queue_row_status() {
    # Usage: n1_queue_row_status <queue.md> <row-number> <status> [reason] [clear]
    # Rewrites the Status (and optionally Reason) cell of the Plan table row
    # whose first cell equals <row-number>. Cells are sanitized (NP-203 SEC-2).
    # An empty reason leaves Reason unchanged unless the 5th arg is "clear" (N1-271: --retry empties it).
    # Row shape: | # | Ticket | Title | Repo | N1 Home | Model | Status | Reason |
    # Sanitized values are passed via ENVIRON[], never awk -v (NP-203 SEC-3): -v assignments
    # undergo string-constant escape processing, so a sanitized value containing a literal
    # `\n` or `\174` would still re-expand into a real newline/`|` inside awk.
    local file="$1" row_num="$2" status reason clr=""
    status=$(_n1_queue_sanitize_cell "$3")
    reason=$(_n1_queue_sanitize_cell "${4:-}")
    [ "${5:-}" = clear ] && clr=1
    local tmp; tmp=$(mktemp "${file}.XXXXXX")
    num="$row_num" st="$status" rsn="$reason" clr="$clr" awk 'BEGIN { FS="|"; OFS="|"; num=ENVIRON["num"]; st=ENVIRON["st"]; rsn=ENVIRON["rsn"]; clr=ENVIRON["clr"] } {
        f2 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
        if (f2 == num && NF >= 9) {
            $8 = " " st " "
            if (rsn != "") $9 = " " rsn " "
            else if (clr != "") $9 = " "
        }
        print
    }' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
}

n1_queue_row_title() {
    # Usage: n1_queue_row_title <queue.md> <row-number> <title>
    # Rewrites the Title cell of the Plan table row whose first cell equals <row-number>
    # (NP-203 SEC-4: lets run.md build the initial Plan table with sanitized, code-written
    # cells instead of relying on prose-only sanitization of untrusted ticket titles).
    local file="$1" row_num="$2" title
    title=$(_n1_queue_sanitize_cell "$3")
    local tmp; tmp=$(mktemp "${file}.XXXXXX")
    num="$row_num" ti="$title" awk 'BEGIN { FS="|"; OFS="|"; num=ENVIRON["num"]; ti=ENVIRON["ti"] } {
        f2 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
        if (f2 == num && NF >= 9) { $4 = " " ti " " }
        print
    }' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
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

n1_queue_row_reason() {
    # Usage: n1_queue_row_reason <queue.md> <num>
    # Prints the Plan row's Reason cell.
    awk -F'|' -v num="$2" '{
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        if ($2 == num) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $9); print $9 }
    }' "$1"
}

n1_queue_parked_rows() {
    # Usage: n1_queue_parked_rows <queue.md>
    # awaiting-human rows still parked on a live question (same columns as
    # n1_queue_pending_rows).
    n1_queue_pending_rows "$1" 'awaiting-human'
}

n1_queue_blocker_of() {
    # Usage: n1_queue_blocker_of <queue.md> <row#> — N1-64: the ticket a held row waits on, from a
    # Reason that starts "blocked_on <ID>" (intake writes it; later notes are appended after " · ").
    n1_queue_row_reason "$1" "$2" | sed -n 's/^blocked_on \([A-Za-z0-9_-]*\).*/\1/p'
}

n1_queue_ticket_status() {
    # Usage: n1_queue_ticket_status <queue.md> <ticket> — Status of the ticket's LAST Plan row
    # (a defer-once retry appends a new row, so the last one is current).
    awk -F'|' -v t="$2" '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
        $2 ~ /^[0-9]+$/ && $3 == t && NF >= 9 { s = $8 } END { print s }' "$1"
}

n1_queue_ticket_obsolete() {
    # Usage: n1_queue_ticket_obsolete <queue.md> <ticket> — N1-362: 0 when the ticket's LAST Plan row is escalated with
    # Reason obsolete (finalize wrote it after n1_queue_child_obsolete passed): nothing to wait for or merge.
    [ "$(awk -F'|' -v t="$2" '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
        $2 ~ /^[0-9]+$/ && $3 == t && NF >= 9 { s = $8 "|" $9 } END { print s }' "$1")" = "escalated|obsolete" ]
}

n1_queue_child_obsolete() {
    # Usage: n1_queue_child_obsolete <ticket> <n1-home> <repo> [start-epoch] — N1-362: 0 only when the child's newest
    # ## Escalations entry is the Headless Guard's "ticket obsolete:" record AND it left no PR (pr_url or open PR) AND no
    # diff (workspace_path HEAD equals memory/<ID>/branch-point, clean tree). The marker alone is child-written and an
    # analysis-stage question also has no diff/PR, so both are required. Fails closed: a missing file, a workspace_path
    # that is not a directory (no fallback to <repo>: its HEAD is not the child's) or any git error returns 1.
    local t="$1" h="$2" repo="$3" start="${4:-}" ov="$2/memory/$1/overview.md" ws bp re='^\[headless\] [^:]+: ticket obsolete:'
    [[ "$(n1_queue_escalation_text "$ov" last)" =~ $re ]] || return 1
    [ -z "$(n1_queue_child_pr_url "$ov")" ] || return 1
    ws=$(n1_read_frontmatter "$ov" workspace_path); [ -n "$ws" ] && [ -d "$ws" ] || return 1
    bp=$(head -n1 "$h/memory/$t/branch-point" 2>/dev/null | tr -d '[:space:]'); [[ "$bp" =~ ^[0-9a-f]{7,40}$ ]] || return 1
    local bpc head
    bpc=$(git -C "$ws" rev-parse --verify -q "$bp^{commit}" 2>/dev/null) && [ -n "$bpc" ] || return 1
    head=$(git -C "$ws" rev-parse --verify -q HEAD 2>/dev/null) && [ "$head" = "$bpc" ] || return 1
    [ -z "$(git -C "$ws" status --porcelain 2>&1)" ] || return 1
    [ -z "$(n1_queue_child_open_pr "$t" "$h" "$repo" "$start")" ]
}

n1_queue_held_sweep() {
    # Usage: n1_queue_held_sweep <queue.md>
    # N1-64: a held row whose blocker ended without a PR (failed/escalated/skip) or is not in the
    # plan can never run: mark it skip. N1-114: when the blocker is at pr and the USER has merged
    # its PR (gh state MERGED), fast-forward the blocker repo's local default branch (children
    # branch from it) and release the row to pending. A gh error, a missing pr_url or a sync
    # failure leaves it held for the next tick (bounded by the runner's held timeout).
    # Prints how many held rows still wait or were just released; a released row is counted so
    # the runner does not stop before launching it. Blocker status is re-read per row, so a
    # chain in plan order resolves in one call; the runner sweeps every idle tick.
    # A blocker PR the user CLOSED unmerged skips the row like a failed blocker.
    # Trust: pr_url is child-written; this only reads PR state and never merges, so a forged
    # URL can at worst release a held row early. Non-GitHub-PR URLs count as not merged (SEC-2).
    # Only a merge into the blocker repo's default branch (story mode: its story branch) releases; any other base stays held.
    # The first gh stderr line goes to the runner's stderr (runner.log), not /dev/null.
    local q="$1" num t b st h r url state base d sb n=0
    while IFS=$'\t' read -r num t _ _ _ _; do
        b=$(n1_queue_blocker_of "$q" "$num"); st=$(n1_queue_ticket_status "$q" "$b")
        [ "$st" = escalated ] && n1_queue_ticket_obsolete "$q" "$b" && st=obsolete
        case "$st" in
            obsolete)   # N1-362: a verified obsolete blocker left nothing to merge
                n1_queue_row_status "$q" "$num" pending "released: $b obsolete" ;;
            failed|escalated|skip|'')
                n1_queue_row_status "$q" "$num" skip "blocked by ${b:-?} (${st:-not in plan})"
                continue ;;
            pr)
                IFS=$'\t' read -r h r < <(n1_queue_pending_rows "$q" pr \
                    | awk -F'\t' -v b="$b" '$2 == b { h = $4; r = $3 } END { printf "%s\t%s\n", h, r }')
                url=$(n1_queue_child_pr_url "$h/memory/$b/overview.md"); state=""; base=""
                if [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+$ ]]; then
                    # gh stdout -> fd 3 (captured), gh stderr -> first line to our stderr.
                    state=$( { gh pr view --json state,baseRefName -q '.state + " " + .baseRefName' -- "$url" </dev/null 2>&1 >&3 3>&- | head -n1 >&2; } 3>&1 )
                    base=${state#* }; state=${state%% *}
                fi
                if [ "$state" = CLOSED ]; then
                    n1_queue_row_status "$q" "$num" skip "blocked by $b (PR closed)"
                    continue
                fi
                sb=$(n1_queue_story_branch_get "$q" "$r")
                if [ -n "$sb" ]; then   # N1-291: a story child's PR targets its story branch; children are cut from origin/<sb>, no local sync
                    [ "$state" = MERGED ] && [ "$base" = "$sb" ] && n1_queue_row_status "$q" "$num" pending "released: $b merged"
                else
                    d=$(N1_HOME="$h" n1_config_val '.git.defaultBranch' 2>/dev/null); d="${d:-main}"
                    if [ "$state" = MERGED ] && [ "$base" = "$d" ] && N1_HOME="$h" n1_queue_sync_default "$r" </dev/null; then
                        n1_queue_row_status "$q" "$num" pending "released: $b merged"
                    fi
                fi ;;
        esac
        n=$((n + 1))
    done < <(n1_queue_pending_rows "$q" held)
    printf '%s' "$n"
}

n1_queue_held_expire() {
    # Usage: n1_queue_held_expire <queue.md> — N1-64: the runner's bounded wait ran out; every
    # remaining held row is skipped (its blocker was never merged). It stays tagged for a later run.
    local q="$1" num t
    while IFS=$'\t' read -r num t _ _ _ _; do
        n1_queue_row_status "$q" "$num" skip "blocked by $(n1_queue_blocker_of "$q" "$num") (not merged)"
    done < <(n1_queue_pending_rows "$q" held)
}

n1_queue_eligible_rows() {
    # Usage: n1_queue_eligible_rows <queue.md> <merge: true|false|function-name>
    # A function name is called with the predecessor row's N1 Home and returns 0 when that home merges its own PRs.
    # N1-303 (the N1-269 eligibility rule): pending Plan rows (n1_queue_pending_rows columns) whose every
    # ## Schedule predecessor is released: at pr (with <merge> true, only once its Runs Outcome is merged, i.e. the
    # queue merged its own PR), done-before-run or escalated with Reason obsolete (N1-362). A failed/escalated/skip
    # predecessor, or one not in the plan, is a
    # hard edge: the row is marked skip here and not listed (the next call cascades). Any other status
    # (pending, in-progress, awaiting-human, held, deferred) waits. No ## Schedule (a plan made before N1-303)
    # lists every pending row. Reads queue.md only (no gh, no stdin): safe on every runner tick (N1-265).
    local q="$1" merge="$2" sched out="" num t rest p st ok why mrg home
    sched=$(n1_queue_schedule_rows "$q")
    while IFS=$'\t' read -r num t rest; do
        ok=1
        for p in $(awk -F'\t' -v t="$t" '$1 == t { gsub(/,/, " ", $2); print $2 }' <<< "$sched"); do
            st=$(n1_queue_ticket_status "$q" "$p")
            [ "$st" = escalated ] && n1_queue_ticket_obsolete "$q" "$p" && st=done-before-run   # N1-362
            case "$st" in
                done-before-run) ;;
                pr)
                    mrg=$merge
                    if [ "$merge" != true ] && [ "$merge" != false ]; then
                        home=$(n1_queue_pending_rows "$q" '.*' | awk -F'\t' -v t="$p" '$2 == t { print $4; exit }')
                        mrg=false; "$merge" "$home" && mrg=true
                    fi
                    if [ "$mrg" = true ] && [ "$(awk -F'|' -v tk="$p" '/^## Runs/ { f = 1; next }
                        f { x = $2; gsub(/ /, "", x); if (x == tk) { o = $5; gsub(/ /, "", o) } } END { print o }' "$q")" != merged ]; then
                        # a chain that ended without merging (Reason finish:<why>) is final unless a merge is still owed
                        why=$(awk -F'|' -v t="$p" '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
                            $2 ~ /^[0-9]+$/ && $3 == t && NF >= 9 { r = $9 } END { print r }' "$q")
                        case "$why" in
                            finish:*) n1_queue_row_status "$q" "$num" skip "predecessor $p not merged (${why%% *})"
                                      ok=0; break ;;
                        esac
                        ok=0
                    fi ;;
                failed|escalated|skip|'')
                    n1_queue_row_status "$q" "$num" skip "predecessor $p ${st:-not in plan}"
                    ok=0; break ;;
                *) ok=0 ;;
            esac
        done
        if [ "$ok" = 1 ]; then out="$out$num"$'\t'"$t"$'\t'"$rest"$'\n'; fi
    done < <(n1_queue_pending_rows "$q")
    printf '%s' "$out"
}

n1_queue_gated_expire() {
    # Usage: n1_queue_gated_expire <queue.md> — N1-303: the runner's bounded wait ran out with no pending row
    # eligible; every pending row left (all gated on a ## Schedule predecessor) is skipped. It stays tagged.
    local q="$1" num t p st blk
    while IFS=$'\t' read -r num t _; do
        blk=""
        for p in $(n1_queue_schedule_rows "$q" | awk -F'\t' -v t="$t" '$1 == t { gsub(/,/, " ", $2); print $2 }'); do
            st=$(n1_queue_ticket_status "$q" "$p")
            [ "$st" = done-before-run ] || { blk="$p"; break; }
        done
        n1_queue_row_status "$q" "$num" skip "predecessor ${blk:+$blk }not released (not at PR or not merged)"
    done < <(n1_queue_pending_rows "$q")
}

n1_queue_sync_default() {
    # Usage: n1_queue_sync_default <repo>
    # N1-64 (CR-1) / N1-114: after the user merges a blocking child's PR, n1_queue_held_sweep
    # fast-forwards the blocker repo's LOCAL default branch before releasing held rows. Children
    # branch from the local default (workspace-isolation.md § Ensure Worktree: `git branch <TARGET> $DEFAULT`),
    # so a stale local default hands a freshly-released ticket a
    # branch-point missing the commit that was just merged. Reads git.defaultBranch from the
    # repo's own N1 Home (caller sets N1_HOME to the blocker's home); falls back to "main".
    # ponytail: single fetch+ff-only, no retry/backoff; add one if flaky CI networks make this noisy.
    local repo="$1" d cur
    [ -d "$repo" ] || { echo "n1-queue: sync: no such repo $repo" >&2; return 1; }
    d=$(n1_config_val '.git.defaultBranch'); d="${d:-main}"
    # SEC-11: d comes from config, not attacker data, but validate before it reaches a refspec.
    git check-ref-format --branch "$d" >/dev/null 2>&1 || { echo "n1-queue: sync: invalid default branch $d" >&2; return 1; }
    git -C "$repo" fetch origin "$d" >&2 || { echo "n1-queue: sync: fetch origin $d failed in $repo" >&2; return 1; }
    cur=$(git -C "$repo" branch --show-current 2>/dev/null)
    if [ "$cur" = "$d" ]; then
        git -C "$repo" merge --ff-only "origin/$d" >&2 || { echo "n1-queue: sync: ff-only merge of $d failed in $repo" >&2; return 1; }
    else
        git -C "$repo" fetch origin "refs/heads/$d:refs/heads/$d" >&2 || { echo "n1-queue: sync: fetch origin $d:$d failed in $repo" >&2; return 1; }
    fi
}

n1_queue_story_branch_ensure() {
    # Usage: n1_queue_story_branch_ensure <repo> <story-id> <default-branch>
    # N1-290: makes origin carry story/<story-id> before a story queue launches its children. A branch already on
    # origin is reused as is (never reset, never force-pushed: resumes keep merged work). An absent one is cut from
    # origin/<default> after a fetch and pushed with a plain push of the remote-tracking ref, so no local branch or
    # checkout is touched. Non-zero with a last stderr line "n1-queue: story branch: <reason>" on any failure.
    local repo="$1" b="story/$2" d="$3" heads
    [ -d "$repo" ] || { echo "n1-queue: story branch: no such repo $repo" >&2; return 1; }
    # SEC-11: validate both names before they reach a refspec. The story id is free-form frontmatter, so it is held
    # to the tracker id grammar first (check-ref-format alone admits quotes, `;`, `|`, `$`); the branch cell
    # written by n1_queue_story_branch_set must then equal the pushed ref.
    case "$2" in ''|-*|*[!A-Za-z0-9._-]*) echo "n1-queue: story branch: invalid story id $2" >&2; return 1 ;; esac
    { [ -n "$2" ] && git check-ref-format --branch "$b" >/dev/null 2>&1; } || { echo "n1-queue: story branch: invalid branch name $b" >&2; return 1; }
    git check-ref-format --branch "$d" >/dev/null 2>&1 || { echo "n1-queue: story branch: invalid default branch $d" >&2; return 1; }
    heads=$(git -C "$repo" ls-remote --heads origin "refs/heads/$b" 2>/dev/null) \
        || { echo "n1-queue: story branch: ls-remote origin failed in $repo" >&2; return 1; }
    [ -z "$heads" ] || return 0
    git -C "$repo" fetch origin "+refs/heads/$d:refs/remotes/origin/$d" >&2 || { echo "n1-queue: story branch: fetch origin $d failed in $repo" >&2; return 1; }
    git -C "$repo" push origin "refs/remotes/origin/$d:refs/heads/$b" >&2 \
        || { echo "n1-queue: story branch: push of $b to origin failed in $repo" >&2; return 1; }
}

n1_queue_story_branch_set() {
    # Usage: n1_queue_story_branch_set <queue.md> <repo> <branch>
    # N1-290: upserts <repo>'s row in the "## Story Branches" table ("| Repo | Branch |"; Repo is the Plan row's
    # Repo cell, so N1-291/292 join on it). A file without the section gets it inserted before ## Runs, which stays
    # last. Repo cell sanitized; a branch the sanitizer would alter is refused. Fails closed (returns 1, file untouched) on more than one "## Story Branches" heading
    # or no "## Runs" line.
    local file="$1" n repo branch tmp
    [ -f "$file" ] || return 1
    n=$(grep -c '^## Story Branches$' "$file" || true)
    { [ "$n" -le 1 ] && grep -q '^## Runs$' "$file"; } || return 1
    repo=$(_n1_queue_sanitize_cell "$2"); branch=$(_n1_queue_sanitize_cell "$3")
    [ "$branch" = "$3" ] || return 1   # a cell that would differ from the pushed ref is never recorded
    tmp=$(mktemp "${file}.XXXXXX")
    has="$n" repo="$repo" branch="$branch" awk '
        BEGIN { FS = "|"; r = ENVIRON["repo"]; row = "| " r " | " ENVIRON["branch"] " |" }
        ENVIRON["has"] == 0 && /^## Runs$/ {
            print "## Story Branches"; print "| Repo | Branch |"; print "|------|--------|"; print row; print ""
        }
        /^## Story Branches$/ { f = 1; print; next }
        f && /^## / { f = 0 }
        f && /^\|[[:space:]]*:?-/ { print; print row; next }
        f && NF >= 4 { c = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); if (c == r) next }
        { print }' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
}

n1_queue_story_branch_get() {
    # Usage: n1_queue_story_branch_get <queue.md> <repo>
    # N1-290: prints the "## Story Branches" branch for <repo>. No file, section or row (tag mode, plans made before
    # N1-290) prints nothing with status 0. More than one "## Story Branches" heading fails closed (nothing, status 1).
    [ -f "$1" ] || return 0
    local n; n=$(grep -c '^## Story Branches$' "$1" || true)
    [ "$n" -le 1 ] || return 1
    r="$(_n1_queue_sanitize_cell "$2")" awk -F'|' '
        BEGIN { r = ENVIRON["r"] }
        /^## Story Branches$/ { f = 1; next }
        /^## / { f = 0 }
        f && NF >= 4 {
            a = $2; b = $3
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", a); gsub(/^[[:space:]]+|[[:space:]]+$/, "", b)
            if (a == r) { print b; exit }
        }' "$1"
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

n1_queue_decisions_row() {
    # Usage: n1_queue_decisions_row <queue.md> <ticket>
    # Prints Touches<TAB>Order<TAB>Pre-Decision<TAB>Desc Checksum<TAB>Notes for <ticket>'s row
    # in the ## Decisions table (NP-203). Fails closed (prints nothing) unless the file has
    # exactly one "## Decisions" heading and exactly one matching row for <ticket> — an
    # untrusted ticket title containing a "## Decisions" line or a forged extra row must
    # never be trusted to authorize a pre-decision (SEC-2). Section-scoped: Plan/Runs rows
    # never match. Fields may be empty: read them with cut -f<N>, not IFS=tab read (collapses).
    [ -f "$1" ] || return 0
    [ "$(grep -c '^## Decisions$' "$1")" = 1 ] || return 0
    awk -F'|' -v t="$2" '
        /^## Decisions$/ { f = 1; next }
        /^## / { f = 0 }
        f {
            for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if ($2 == t && NF >= 8) { matches++; row = sprintf("%s\t%s\t%s\t%s\t%s", $3, $4, $5, $6, $7) }
        }
        END { if (matches == 1) print row }' "$1"
}

n1_queue_decisions_write_row() {
    # Usage: n1_queue_decisions_write_row <queue.md> <ticket> <touches> <order> <predecision> <checksum> <notes>
    # Replaces the ## Decisions row for <ticket> in place; every cell is sanitized (NP-203
    # CR-2), the write-side counterpart of n1_queue_decisions_row's fail-closed read. No-op
    # (returns 0) when the file or the row is missing; fails closed (CR-5, mirrors the reader's
    # own guard) unless the file has exactly one `^## Decisions$` heading — an untrusted title
    # containing a forged heading line must never be allowed to redirect this write.
    local file="$1" ticket="$2"
    [ -f "$file" ] || return 0
    [ "$(grep -c '^## Decisions$' "$file")" = 1 ] || return 1
    local touches order predecision checksum notes
    touches=$(_n1_queue_sanitize_cell "$3")
    order=$(_n1_queue_sanitize_cell "$4")
    predecision=$(_n1_queue_sanitize_cell "$5")
    checksum=$(_n1_queue_sanitize_cell "$6")
    notes=$(_n1_queue_sanitize_cell "$7")
    local tmp; tmp=$(mktemp "${file}.XXXXXX")
    # Sanitized values are passed via ENVIRON[], never awk -v (NP-203 SEC-3): see
    # n1_queue_row_status for why -v's escape processing would undo the sanitizer.
    t="$ticket" touches="$touches" order="$order" pd="$predecision" cksum="$checksum" notes="$notes" awk '
        BEGIN {
            FS = "|"
            t=ENVIRON["t"]; touches=ENVIRON["touches"]; order=ENVIRON["order"]
            pd=ENVIRON["pd"]; cksum=ENVIRON["cksum"]; notes=ENVIRON["notes"]
        }
        /^## Decisions$/ { f = 1; print; next }
        /^## / { f = 0 }
        f {
            f2 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
            if (f2 == t && NF >= 8) {
                printf "| %s | %s | %s | %s | %s | %s |\n", f2, touches, order, pd, cksum, notes
                next
            }
        }
        { print }
    ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
}

n1_queue_content_hash() {
    # Usage: n1_queue_content_hash <title-file> <desc-file>
    # Prints sha256(contents of <title-file> + "\n" + contents of <desc-file>): sha256sum,
    # shasum -a 256 fallback (NP-203 SEC-3 — replaces cksum/CRC32, which is trivially
    # forgeable). Both arguments are files, never inline text (NP-203 SEC-1): a ticket title
    # is untrusted tracker text, and interpolating it into a shell string executed by a
    # headless child is command injection (CWE-78) — hooks/desc-capture.sh writes both files
    # from the tracker fetch (N1-326). Fails closed (SEC-5): prints nothing and returns 1
    # when either file is missing, so a fetch failure never silently hashes as "unchanged".
    # Shared by preview.md's Desc Checksum snapshot, run.md's staleness re-check, and the
    # child-side TOCTOU guard in autonomy-headless-predecision.md, so all three agree on one definition
    # of "changed".
    [ -f "$1" ] || return 1
    [ -f "$2" ] || return 1
    { cat "$1"; printf '\n'; cat "$2"; } | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | cut -d' ' -f1
}

n1_desc_mark() {
    # Usage: n1_desc_mark <pre|post|guard|queue> <KEY> [<queue-id>]
    # N1-326: one-shot destination marker for hooks/desc-capture.sh. Run it in its own bash call right
    # before the tracker read of <KEY>; the hook then writes that fetch's title/description to
    # memory/<KEY>/.desc-pre|.desc-post|.guard-live.{title,txt} or queue/<queue-id>/desc/<KEY>.{title,txt}.
    # Writes $N1_HOME/.desc-marker/<session-id>/<KEY> holding validated tokens only (never a path, never
    # tracker text); re-marking a key overwrites. Sweeps markers older than 60 minutes first.
    # Returns 1 and writes nothing on a bad kind, key, queue id or session id.
    local kind="${1:-}" key="${2:-}" qid="${3:-}" sid dir line
    type n1_session_id >/dev/null 2>&1 || return 1
    sid=$(n1_session_id)
    [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || return 1
    case "$kind" in
        pre|post|guard) [ -z "$qid" ] || return 1; line=$kind ;;
        queue) [[ "$qid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1; line="queue $qid" ;;
        *) return 1 ;;
    esac
    [ -n "${N1_HOME:-}" ] || return 1
    dir="$N1_HOME/.desc-marker"
    [ ! -L "$dir" ] || return 1
    find "$dir" -type f -mmin +60 -delete 2>/dev/null
    find "$dir" -mindepth 1 -type d -empty -delete 2>/dev/null
    dir="$dir/$sid"
    mkdir -p "$dir" 2>/dev/null && [ ! -L "$dir" ] || return 1
    rm -f "$dir/$key"
    printf '%s\n' "$line" > "$dir/$key"
}

n1_desc_unmark() {
    # Usage: n1_desc_unmark <KEY>: drop this session's pending capture marker for <KEY> (desc-hash-chain Gate).
    local key="${1:-}" sid
    type n1_session_id >/dev/null 2>&1 || return 1
    sid=$(n1_session_id)
    [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] && [[ "$key" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] && [ -n "${N1_HOME:-}" ] || return 1
    rm -f "$N1_HOME/.desc-marker/$sid/$key"
}

n1_desc_hash_is_trusted() {
    # Usage: n1_desc_hash_is_trusted <ticket-id> <sha256>
    # NP-231 trusted-hash chain. Exit 0 when <sha256> is the ticket's plan-time Desc Checksum or a
    # hash this queue run recorded after one of N1's own description writes (n1_desc_hash_record);
    # exit 1 otherwise. Hashes come only from n1_queue_content_hash over file-written tracker text
    # (SEC-1). Fails closed (SEC-5): a malformed id/hash, no trustworthy plan (N1_QUEUE_DIR or
    # N1_QUEUE_RUN_ID unset, or queue.md run_id mismatch, SEC-L1), or an empty plan checksum
    # trusts nothing; a missing/unreadable .desc-hashes leaves only the plan hash.
    local id="$1" h="$2" plan f
    [[ "$id" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || return 1
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ -n "${N1_QUEUE_DIR:-}" ] && [ -n "${N1_QUEUE_RUN_ID:-}" ] || return 1
    [ "$(n1_read_frontmatter "$N1_QUEUE_DIR/queue.md" run_id 2>/dev/null)" = "$N1_QUEUE_RUN_ID" ] || return 1
    plan=$(n1_queue_decisions_row "$N1_QUEUE_DIR/queue.md" "$id" 2>/dev/null | cut -f4)
    [ -n "$plan" ] || return 1
    [ "$h" = "$plan" ] && return 0
    f="${N1_HOME:-}/memory/$id/.desc-hashes"
    [ -n "${N1_HOME:-}" ] && [ -r "$f" ] || return 1
    RID="$N1_QUEUE_RUN_ID" H="$h" awk -F'\t' '$1 == ENVIRON["RID"] && $2 == ENVIRON["H"] { ok = 1 } END { exit !ok }' "$f" 2>/dev/null
}

n1_desc_hash_record() {
    # Usage: n1_desc_hash_record <ticket-id> <pre-write-sha256> <post-write-sha256>
    # NP-231: append "<N1_QUEUE_RUN_ID>\t<post>" to $N1_HOME/memory/<id>/.desc-hashes only when
    # <pre> (the live hash snapshotted right before N1's tracker write) is already trusted, so a
    # human edit that landed before the write is never laundered into the trusted set.
    # Exit 1 and record nothing on any failure (SEC-5).
    # ponytail: check-then-write window; a human edit landing between N1's write and its
    # re-fetch is absorbed. Single writer per ticket in queue runs; close with a tracker-side
    # conditional update (version/ETag) if it bites.
    local id="$1" pre="$2" post="$3"
    n1_desc_hash_is_trusted "$id" "$pre" || return 1
    [[ "$post" =~ ^[0-9a-f]{64}$ ]] || return 1
    [ -n "${N1_HOME:-}" ] || return 1
    mkdir -p "$N1_HOME/memory/$id" && printf '%s\t%s\n' "$N1_QUEUE_RUN_ID" "$post" >> "$N1_HOME/memory/$id/.desc-hashes"
}

n1_queue_stale() {
    # Usage: n1_queue_stale <queue.md>
    # Exit 0 when frontmatter planned_at is older than queue.staleAfterHours (default 24),
    # missing/unparseable, or in the future (a future planned_at is clock skew or a forged
    # timestamp, never grounds to treat the plan as fresh — NP-203 SEC-L3). Exit 1 when fresh.
    local at epoch hours diff
    at=$(n1_read_frontmatter "$1" planned_at)
    [ -n "$at" ] || return 0
    epoch=$(date -u -d "$at" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$at" +%s 2>/dev/null) || return 0
    hours=$(n1_queue_val staleAfterHours)
    case "$hours" in ''|*[!0-9]*) hours=24 ;; esac
    diff=$(( $(date -u +%s) - epoch ))
    [ "$diff" -lt 0 ] && return 0
    [ "$diff" -gt $(( hours * 3600 )) ]
}

n1_queue_overlap_order() {
    # Usage: printf '%s\t%s\n' <ticket> <touches> ... | n1_queue_overlap_order
    # Prints "<ticket>\t<note>" in execution order (NP-203). Tickets whose comma-separated
    # Touches share a token (case-insensitive) run lowest ticket number first; all other
    # ordering keeps input order. Note: "after <ticket> (<token>)" for the nearest earlier
    # overlapping ticket. A ticket with NO overlap relationship at all (it never blocks and
    # is never blocked) can still get bumped ahead of its input position as a side effect of
    # the ready-scan skipping a blocked, unrelated ticket; that case is flagged
    # "moved up (unrelated overlap elsewhere)" so the plan table never shows a silent
    # reorder with no explanation. All other unchanged slots print an empty note.
    # ponytail: O(n^3) Kahn sort; fine at queue.maxTickets scale, index tokens if batches grow.
    awk -F'\t' '
    function num(k) { sub(/.*-/, "", k); return k + 0 }
    function shared(a, b,    m, i, c, arr) {
        m = split(list[a], arr, ",")
        for (i = 1; i <= m; i++) { c = arr[i]; if (c != "" && ((b, c) in has)) return c }
        return ""
    }
    {
        n++; key[n] = $1; list[n] = ""
        m = split(tolower($2), parts, ",")
        for (i = 1; i <= m; i++) {
            c = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
            if (c != "" && !((n, c) in has)) { has[n, c] = 1; list[n] = list[n] "," c }
        }
    }
    END {
        for (a = 1; a <= n; a++)
            for (b = 1; b <= n; b++)
                if (a != b && shared(a, b) != "") { related[a] = 1; related[b] = 1 }
        for (out = 1; out <= n; out++) {
            for (i = 1; i <= n; i++) {
                if (done[i]) continue
                ready = 1
                for (j = 1; j <= n; j++)
                    if (!done[j] && j != i && num(key[j]) < num(key[i]) && shared(i, j) != "") { ready = 0; break }
                if (ready) break
            }
            done[i] = 1; seq[out] = i; note = ""
            for (k = out - 1; k >= 1; k--) { c = shared(i, seq[k]); if (c != "") { note = "after " key[seq[k]] " (" c ")"; break } }
            if (note == "" && !related[i] && out != i) note = "moved up (unrelated overlap elsewhere)"
            printf "%s\t%s\n", key[i], note
        }
    }'
}

n1_queue_overlap_preds() {
    # Usage: printf '%s\t%s\t%s\n' <ticket> <touches> <blocker-or-empty> ... | n1_queue_overlap_preds
    # N1-303: prints "<ticket>\t<after>" per input line in input (execution) order. <after> is the comma list of
    # EVERY earlier ticket sharing a Touches token (case-insensitive, trimmed: the tokens n1_queue_overlap_order
    # uses). Overlap is not transitive, so this is not only the nearest overlapper an Order note names.
    # N1-318: Blocks always wins over overlap. An earlier ticket j is not listed when j already depends on this
    # ticket (directly or transitively) through Blocks edges plus overlap edges kept so far: that edge would
    # close a cycle and nothing would start. Blockers outside the input are ignored.
    awk -F'\t' '
    function reach(from, to,    sp, st, v, k, m, p) {   # does `from` depend on `to`?
        delete vis; sp = 1; st[1] = from; vis[from] = 1
        while (sp > 0) {
            v = st[sp--]
            if (v == to) return 1
            if ((blk[v] in idx) && !vis[idx[blk[v]]]) { vis[idx[blk[v]]] = 1; st[++sp] = idx[blk[v]] }
            m = split(kept[v], p, ",")
            for (k = 1; k <= m; k++) if (p[k] != "" && !vis[p[k]]) { vis[p[k]] = 1; st[++sp] = p[k] }
        }
        return 0
    }
    $1 != "" && !seen[$1]++ {
        n++; key[n] = $1; blk[n] = $3; idx[$1] = n; np[n] = split(tolower($2), parts, ",")
        for (i = 1; i <= np[n]; i++) {
            c = parts[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c)
            if (c != "") has[n, c] = 1; tok[n, i] = c
        }
    }
    END {
        for (x = 1; x <= n; x++) {
            after = ""
            for (j = 1; j < x; j++)
                for (i = 1; i <= np[x]; i++)
                    if (tok[x, i] != "" && ((j, tok[x, i]) in has)) {
                        if (!reach(j, x)) { after = after (after == "" ? "" : ",") key[j]; kept[x] = kept[x] "," j }
                        break
                    }
            print key[x] "\t" after
        }
    }'
}

n1_queue_waves() {
    # Usage: <ticket>\t<after> lines | n1_queue_waves
    # N1-303: one display line, "wave 1: A, C | wave 2: B (after A)". wave = 1 + the highest wave among the
    # listed predecessors that are in the input (others are shown but ignored). A repeated ticket unions its
    # lists (held Blocks edges are appended as extra lines). Input order within a wave.
    awk -F'\t' '
    $1 == "" { next }
    !($1 in idx) { n++; key[n] = $1; idx[$1] = n }
    $2 != "" { aft[$1] = aft[$1] (aft[$1] == "" ? "" : ",") $2 }
    END {
        for (i = 1; i <= n; i++) w[i] = 1
        for (pass = 1; pass <= n; pass++) {   # relax to a fixed point; a cycle stops after n passes
            ch = 0
            for (i = 1; i <= n; i++) {
                m = split(aft[key[i]], p, ",")
                for (k = 1; k <= m; k++)
                    if ((p[k] in idx) && w[idx[p[k]]] + 1 > w[i]) { w[i] = w[idx[p[k]]] + 1; ch = 1 }
            }
            if (!ch) break
        }
        if (ch) { print "cycle in schedule (dependencies loop; re-plan)"; exit }
        top = 0; for (i = 1; i <= n; i++) if (w[i] > top) top = w[i]
        out = ""
        for (v = 1; v <= top; v++) {
            s = ""
            for (i = 1; i <= n; i++) if (w[i] == v) {
                s = s (s == "" ? "" : ", ") key[i]
                if (aft[key[i]] != "") { a = aft[key[i]]; gsub(/,/, ", ", a); s = s " (after " a ")" }
            }
            if (s != "") out = out (out == "" ? "" : " | ") "wave " v ": " s
        }
        print out
    }'
}

n1_queue_schedule_rows() {
    # Usage: n1_queue_schedule_rows <queue.md>
    # N1-303: prints "<ticket>\t<after>" per ## Schedule row. Fails closed (prints nothing, i.e. no predecessors:
    # the pre-N1-303 behaviour) unless the file has exactly one "## Schedule" heading. Only ticket keys
    # (^[A-Z][A-Z0-9_]*-[0-9]+$) pass; any other After entry is dropped.
    [ -f "$1" ] || return 0
    [ "$(grep -c '^## Schedule$' "$1" || true)" = 1 ] || return 0
    awk -F'|' '
        function key(s) { return s ~ /^[A-Z][A-Z0-9_]*-[0-9]+$/ }
        /^## Schedule$/ { f = 1; next }
        /^## / { f = 0 }
        f && NF >= 4 {
            for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            if (!key($2)) next
            m = split($3, p, ","); a = ""
            for (k = 1; k <= m; k++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", p[k])
                if (key(p[k])) a = a (a == "" ? "" : ",") p[k]
            }
            print $2 "\t" a
        }' "$1"
}

n1_queue_schedule_write() {
    # Usage: n1_queue_schedule_write <queue.md>
    # N1-303: (re)writes the whole ## Schedule section ("| Ticket | After |") from the pending/held Plan rows in
    # physical order and their ## Decisions Touches, via n1_queue_overlap_preds. Idempotent. A plan without the
    # section (made before N1-303, being re-planned) gets it inserted before ## Runs, which stays last.
    # Fails closed (returns 1, file untouched) on more than one "## Schedule" heading or no "## Runs" line.
    local file="$1" n rows tmp num
    [ -f "$file" ] || return 1
    n=$(grep -c '^## Schedule$' "$file" || true)
    { [ "$n" -le 1 ] && grep -q '^## Runs$' "$file"; } || return 1
    rows=$(while IFS=$'\t' read -r num t _; do
            printf '%s\t%s\t%s\n' "$t" "$(n1_queue_decisions_row "$file" "$t" | cut -f1)" "$(n1_queue_blocker_of "$file" "$num")"
        done < <(n1_queue_pending_rows "$file" 'pending|held') | n1_queue_overlap_preds \
        | while IFS=$'\t' read -r t a; do
            printf '| %s | %s |\n' "$(_n1_queue_sanitize_cell "$t")" "$(_n1_queue_sanitize_cell "$a")"
        done)
    tmp=$(mktemp "${file}.XXXXXX")
    has="$n" rows="$rows" awk '
        function emit() {
            print "## Schedule"; print "| Ticket | After |"; print "|--------|-------|"
            if (ENVIRON["rows"] != "") print ENVIRON["rows"]
            print ""
        }
        ENVIRON["has"] == 0 && /^## Runs$/ { emit() }
        /^## Schedule$/ { emit(); skip = 1; next }
        skip && /^## / { skip = 0 }
        skip { next }
        { print }' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; false; }
}

n1_queue_plan_waves() {
    # Usage: n1_queue_plan_waves <queue.md>
    # N1-303: the saved plan's wave line, built like the preview's: the ## Schedule edges plus each held row's
    # Blocks blocker (display-only; the held sweep gates those at run time, they are never stored).
    local q="$1" num t
    { n1_queue_schedule_rows "$q"
      while IFS=$'\t' read -r num t _; do
          printf '%s\t%s\n' "$t" "$(n1_queue_blocker_of "$q" "$num")"
      done < <(n1_queue_pending_rows "$q" held)
    } | n1_queue_waves
}

n1_queue_release_rows() {
    # Usage: n1_queue_release_rows <queue.md>
    # Prints unique "<ticket>\t<n1-home>" for tag-mode Plan rows with a handoff outcome
    # (pr, escalated, failed, stopped) whose overview.md lacks queue_tag_removed: true.
    local q="$1" t h
    [ "$(n1_read_frontmatter "$q" mode)" = tag ] || return 0
    n1_queue_pending_rows "$q" 'pr|escalated|failed|stopped' | cut -f2,4 | sort -u |
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
    id=$(printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*backgrounded[^0-9a-f]*\([0-9a-f]\{8\}\).*/\1/p' | head -1)
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

n1_queue_live_by_name() {
    # Usage: n1_queue_live_by_name <agents-json> <name> — N1-82: 8-hex id of a working/blocked
    # background session with exactly that name, else nothing. Names repeat across runs, so the
    # runner trusts a match only when its per-row launch lock holds the current run id.
    printf '%s' "$1" | jq -r --arg n "$2" '
        [.. | objects | select(has("state") and .name == $n and (.state == "working" or .state == "blocked"))][0] // empty
        | ((.id // ((.sessionId // "")[:8])) | tostring) | select(test("^[0-9a-f]{8}$"))' 2>/dev/null
    return 0
}

n1_queue_answer() {
    # Usage: n1_queue_answer <n1-home> <ticket>
    # N1-55: relays a main-thread answer to a queue child blocked on a question it mirrored to
    # <queue-dir>/.question-<ticket>.json: stop its session, then bg-resume it with
    # "[n1-queue answer] <answer>". The answer is read from <n1-home>/queue/.answer-<ticket>.txt (never
    # shell-interpolated; path derived only after the ticket id is validated, SEC-4) and
    # capped at 4000 chars. Resume requires the FULL sessionId and passes no other flags (spike
    # evidence, N1-55: --resume with --permission-mode/--settings/--model forks a new session id
    # instead of continuing the same one; a flag-less full-id resume restores the child's saved
    # launch options automatically). <queue-dir>/.relay-<ticket> tells the runner the stopped gap
    # is a relay (n1_queue_relay_active); it expires on its own, since the agents list can lag the
    # resume. A retry after a failed resume skips the stop (session already stopped).
    # The answer file is read then deleted first, on every path (never reused for another call);
    # on success the question file is removed.
    local home="$1" t="$2" af qf dir row sid agents st full ans run i
    case "$t" in ''|*[!A-Za-z0-9_-]*) echo "n1-queue: invalid ticket id" >&2; return 1 ;; esac
    af="$home/queue/.answer-$t.txt"
    ans=$(cat "$af" 2>/dev/null); rm -f "$af"
    qf=$(ls -t "$home"/queue/*/.question-"$t".json "$home"/queue/*/.ask-"$t" 2>/dev/null | head -1)
    [ -n "$qf" ] || { echo "n1-queue: no pending question for $t" >&2; return 1; }
    dir="${qf%/*}"
    # N1-225: an Orca child waits on an orchestration ask, not a bg session.
    if [ -f "$dir/.ask-$t" ]; then
        [ -n "$ans" ] || { echo "n1-queue: empty answer" >&2; return 1; }
        [ "${#ans}" -le 4000 ] || ans="${ans:0:4000}... [truncated]"
        n1_orca_reply "$dir" "$t" "$ans"
        return
    fi
    row=$(n1_queue_pending_rows "$dir/queue.md" 'awaiting-human' | awk -F'\t' -v t="$t" '$2 == t')
    sid=$(n1_queue_session_id "$dir/queue.md" "$t")
    case "$sid" in orca:*) echo "n1-queue: $t has no pending Orca question" >&2; return 1 ;; esac
    { [ -n "$row" ] && [ -n "$sid" ]; } || { echo "n1-queue: $t is not waiting in a queue session" >&2; return 1; }
    agents=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null)
    st=$(n1_queue_bg_state "$agents" "$sid")
    case "$st" in blocked|failed) ;; *) echo "n1-queue: session $sid is $st, not waiting for an answer" >&2; return 1 ;; esac
    full=$(printf '%s' "$agents" | jq -r --arg sid "$sid" \
        '[.. | objects | select(has("state")) | select(.id == $sid or ((.sessionId // "") | startswith($sid)))][0].sessionId // empty' 2>/dev/null)
    [ -n "$full" ] || { echo "n1-queue: could not resolve the full session id for $sid; retry, or: $(n1_bg_cmd attach "$sid")" >&2; return 1; }
    [ -n "$ans" ] || { echo "n1-queue: empty answer" >&2; return 1; }
    [ "${#ans}" -le 4000 ] || ans="${ans:0:4000}... [truncated]"
    : > "$dir/.relay-$t"; rm -f "$dir/.esc-reason-$t"  # N1-241: a re-asked escalation fires again
    if [ "$st" = blocked ]; then
        if ! bash -c "$(n1_bg_cmd stop "$sid")"; then
            rm -f "$dir/.relay-$t"; echo "n1-queue: could not stop session $sid" >&2; return 1
        fi
        for i in 1 2 3 4 5; do  # bounded wait for the stop to land; resume is attempted regardless
            case "$(n1_queue_bg_state "$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null)" "$sid")" in
                working|blocked) sleep 2 ;; *) break ;; esac
        done
    fi
    if ! bash -c "$(n1_bg_cmd resume "$full" "[n1-queue answer] $ans")"; then
        # The session is stopped by now (this call or an earlier one): attach no longer reaches it.
        echo "n1-queue: resume failed for $t; retry --answer within 2 minutes, or: $(n1_bg_cmd reopen "$full")" >&2
        return 1
    fi
    rm -f "$qf"
    run=$(n1_read_frontmatter "$dir/queue.md" run_id)
    n1_queue_event "$dir/events.jsonl" "$(n1_read_frontmatter "$dir/queue.md" queue_id)" "$run" answer_delivered \
        ticket="$t" session="$sid" reason="${ans:0:120}"
    echo "n1-queue: answer delivered to $t (session $sid), resuming."
}

n1_queue_relay_active() {
    # Usage: n1_queue_relay_active <queue-dir> <ticket> — exit 0 while n1_queue_answer's relay
    # marker is under 2 minutes old (N1-55); older markers are ignored.
    [ -n "$(find "$1/.relay-$2" -mmin -2 2>/dev/null)" ]
}

n1_queue_runner_alive() {
    # Usage: n1_queue_runner_alive <pid> [<queue.md>] — N1-183: exit 0 when <pid> is a live queue
    # runner. kill -0 alone trusts a recycled pid; where /proc exists the NUL-split cmdline must carry
    # an argument ending in scripts/n1-queue-run.sh and, when <queue.md> is given, that exact path as
    # the next argument (a runner of another queue, or `less n1-queue-run.sh`, is not this runner).
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    [ -r "/proc/$1/cmdline" ] || return 0
    local arg hit=""
    while IFS= read -r -d '' arg; do
        if [ -n "$hit" ]; then { [ -z "${2:-}" ] || [ "$arg" = "$2" ]; } && return 0; return 1; fi
        case "$arg" in */scripts/n1-queue-run.sh|scripts/n1-queue-run.sh) hit=1 ;; esac
    done < "/proc/$1/cmdline" 2>/dev/null
    return 1
}

n1_queue_interrupted() {
    # Usage: n1_queue_interrupted <queue.md> — N1-183: exit 0 when the run says step: run but its
    # runner is gone (killed with the launching session, crashed, or host restart).
    [ -f "$1" ] && [ "$(n1_read_frontmatter "$1" step)" = run ] || return 1
    ! n1_queue_runner_alive "$(n1_read_frontmatter "$1" pid)" "$1"
}

n1_queue_note_interrupt() {
    # Usage: n1_queue_note_interrupt <queue.md> <why> — N1-333: the runner's exit trace. Only while step is run (halt_now
    # and the normal end write halted/done first, so they stay silent): prints one runner.log line and appends one
    # queue_interrupted event. Never changes step or pid, so n1_queue_interrupted still finds the dead runner and --run resumes.
    local q="$1" pid qid run
    [ -f "$q" ] && [ "$(n1_read_frontmatter "$q" step)" = run ] || return 0
    pid=$(n1_read_frontmatter "$q" pid); qid=$(n1_read_frontmatter "$q" queue_id); run=$(n1_read_frontmatter "$q" run_id)
    printf 'runner interrupted: %s (pid %s, step run kept; resume: /n1:n1-queue --run %s)\n' "$2" "${pid:-?}" "${qid:-queue}"
    n1_queue_event "$(dirname "$q")/events.jsonl" "${qid:-queue}" "$run" queue_interrupted reason="runner $2 pid ${pid:-?}"
    return 0
}

n1_queue_retry() {
    # Usage: n1_queue_retry <queue.md> <ticket> — N1-271 (n1-queue --retry): reset the ticket's last Plan row from
    # failed/escalated to pending (Reason cleared) in a planned, halted, done or interrupted queue; drop the previous
    # attempt's markers and Orca identity (the next launch writes a fresh one); set a halted/done queue to step: run so
    # `--run <id>` resumes it through the interrupted-run path under the same run_id. Never starts the runner.
    # Refuses (stderr, exit 1, nothing changed): invalid ticket id, no queue, live runner, another step, no row, or
    # a row in another status.
    local q="$1" t="$2" dir step row num st n1h task
    [[ "$t" =~ ^[A-Za-z][A-Za-z0-9_]*-[0-9]+$ ]] || { echo "n1-queue: invalid ticket id: $t" >&2; return 1; }
    [ -n "$q" ] && [ -f "$q" ] || { echo "No queue runs found." >&2; return 1; }
    dir=$(dirname -- "$q")
    if n1_queue_runner_alive "$(n1_read_frontmatter "$q" pid)" "$q"; then
        echo "n1-queue: queue $(n1_read_frontmatter "$q" queue_id) is running; retry once it ends" >&2; return 1
    fi
    step=$(n1_read_frontmatter "$q" step)
    case "$step" in planned|halted|done|run) ;; *) echo "n1-queue: queue step '${step:-none}' cannot be retried" >&2; return 1 ;; esac
    row=$(n1_queue_pending_rows "$q" '.*' | awk -F'\t' -v t="$t" '$2 == t { r = $0 } END { print r }')
    [ -n "$row" ] || { echo "n1-queue: no row for $t" >&2; return 1; }
    IFS=$'\t' read -r num _ _ n1h _ st <<< "$row"
    case "$st" in failed|escalated) ;; *) echo "n1-queue: $t is ${st:-empty}, not failed or escalated" >&2; return 1 ;; esac
    declare -F n1_orca_sentinel_rm >/dev/null || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/orca-queue.sh" || return 1
    # SEC-1: the identity file, not the Runs row, says whether a worker may be live (launch keeps it on a worker-start
    # timeout, with an empty Runs Session). Retry drops that identity and its session pins, so refuse unless a readable
    # worker list shows no worker for its task still running (none listed = never started, as the runner decides).
    # An unreadable list, or an identity without task or run, refuses too (fail closed).
    task=$(n1_orca_identity_guard "$n1h" "$t" "$(n1_read_frontmatter "$q" orca_run_id)") || {
        echo "n1-queue: $t's previous worker may still be running; stop it first (/n1:n1-queue --stop)" >&2; return 1
    }
    # Flip the step first so a failed write changes nothing; restore it if the row reset then fails.
    case "$step" in halted|done) n1_write_frontmatter "$q" step run || { echo "n1-queue: could not set step run on $q" >&2; return 1; } ;; esac
    n1_queue_row_status "$q" "$num" pending "" clear || { n1_write_frontmatter "$q" step "$step" || true; return 1; }
    rm -f "$dir/.launch-$num" "$dir/.esc-reason-$t" "$dir/.ask-$t" "$dir/.escalated-$t" "$dir/.question-$t.json" \
        || { echo "n1-queue: could not clear retry markers in $dir" >&2; return 1; }
    [ -z "$n1h" ] || n1_orca_sentinel_rm "$n1h" "$t" "$task" || { echo "n1-queue: could not remove $t's Orca identity" >&2; return 1; }
    echo "Retry queued: /n1:n1-queue --run $(n1_read_frontmatter "$q" queue_id)"
}

n1_queue_claim() {
    # Usage: n1_queue_claim <queue-dir> — N1-226: take the unattended-run claim <queue-dir>/.unattended-claim
    # (mkdir is atomic). Non-zero while another trigger holds a claim under 15 minutes old; an older claim is
    # retaken by creating the marker <claim>/retake.<claim mtime> (one winner per generation; the claim dir is
    # never removed or renamed). Never released: it expires, so a trigger closer than 15 minutes after a start
    # is skipped. scripts/n1-queue-precheck.sh reads the same path and age.
    local c="$1/.unattended-claim" m
    mkdir -p "$1" 2>/dev/null || return 1
    mkdir "$c" 2>/dev/null && return 0
    # One stat feeds both the age test and the generation name; a separate find then stat would let a late
    # contender win twice. The marker mkdir also refreshes the claim mtime.
    m=$(stat -c %Y "$c" 2>/dev/null || stat -f %m "$c" 2>/dev/null) || return 1
    [ $(( $(date +%s) - m )) -ge 900 ] || return 1
    # Ceiling: a contender stalled more than 30 minutes between its stat and this mkdir could re-win a
    # generation whose marker was already cleaned.
    mkdir "$c/retake.$m" 2>/dev/null || return 1
    find "$c" -mindepth 1 -maxdepth 1 -name 'retake.*' -mmin +30 -exec rmdir {} + 2>/dev/null
    return 0
}

n1_queue_orca_scan() {
    # Usage: n1_queue_orca_scan <queue.md> — N1-270: park each Orca row whose worker asked a question the
    # runner never saw (see n1_queue_interrupted_note). No-op without orca_run_id.
    local q="$1" ev run qid d num t msg
    ev="$(dirname "$q")/events.jsonl"
    run=$(n1_read_frontmatter "$q" run_id); qid=$(n1_read_frontmatter "$q" queue_id)
    if [ -n "$(n1_read_frontmatter "$q" orca_run_id)" ] && declare -F n1_orca_pending_questions >/dev/null; then
        d=$(dirname "$q")
        while IFS=$'\t' read -r -u 3 num t msg; do
            # noclobber makes the create the atomic claim: concurrent scans or two questions for one ticket, first wins, one event
            ( set -o noclobber; printf '%s\n' "$msg" > "$d/.ask-$t" ) 2>/dev/null || continue
            # N1-309: a final row (failed/pr/escalated) keeps its status; n1_queue_awaiting_hints lists its .ask marker.
            if [ -n "$(n1_queue_pending_rows "$q" 'in-progress|awaiting-human' | awk -F'\t' -v n="$num" '$1 == n')" ]; then
                n1_queue_row_status "$q" "$num" awaiting-human
            fi
            n1_queue_event "$ev" "$qid" "$run" escalated ticket="$t" session="$(n1_queue_session_id "$q" "$t")" \
                reason="worker question pending, runner down"
            n1_notify needs-you "$t needs you: worker question pending, runner down (answer: /n1:n1-queue --answer $t <text>)"
        done 3< <(n1_orca_pending_questions "$d")
    fi
}

n1_queue_finished_scan() {
    # Usage: n1_queue_finished_scan <queue.md> — N1-270: a done/halted queue can still own an awaiting-human
    # Orca row (the runner leaves its sink open); scan so a later worker question still surfaces.
    case "$(n1_read_frontmatter "$1" step)" in done|halted) n1_queue_orca_scan "$1" ;; esac
}

n1_queue_interrupted_note() {
    # Usage: n1_queue_interrupted_note <queue.md> — N1-183: for an interrupted run, append one
    # queue_interrupted event per run id (later calls only print) and print the resume line.
    # N1-270: an Orca worker question that reached the Run inbox after the runner died parks its row
    # with the runner's .ask marker (--answer finds it; n1_queue_awaiting_hints prints the command),
    # one escalated event and a needs-you alert. The marker dedupes later calls; a resumed runner
    # sees the parked row and does not re-escalate. Prints nothing for a run that is not interrupted.
    local q="$1" ev run qid pid
    n1_queue_interrupted "$q" || return 0
    ev="$(dirname "$q")/events.jsonl"
    run=$(n1_read_frontmatter "$q" run_id); qid=$(n1_read_frontmatter "$q" queue_id); pid=$(n1_read_frontmatter "$q" pid)
    if [ -z "$(jq -R --arg r "$run" 'fromjson? | select(.event == "queue_interrupted" and .run_id == $r)' "$ev" 2>/dev/null)" ]; then
        n1_queue_event "$ev" "$qid" "$run" queue_interrupted reason="runner pid ${pid:-?} gone"
    fi
    n1_queue_orca_scan "$q"
    printf 'interrupted: runner pid %s is gone; resume: /n1:n1-queue --run %s\n' "${pid:-?}" "$qid"
}

n1_queue_awaiting_hints() {
    # Usage: n1_queue_awaiting_hints <queue.md>
    # Prints "<ticket>: <resume command>" for each Plan row waiting on a human: an attach
    # command for parked sessions, --answer for Orca rows. N1-309: also a final (failed/pr/escalated)
    # row whose worker question is still pending (<queue-dir>/.ask-<ticket>), whatever its status.
    local file="$1" t h sid st task
    while IFS=$'\t' read -r _ t _ h _ st; do
        sid=$(n1_queue_session_id "$file" "$t")
        if [ "$st" != awaiting-human ]; then
            # final row: only while its sentinel still names the task (a settled worker's .ask is stale); fail closed
            [ -e "$(dirname "$file")/.ask-$t" ] && declare -F _n1_orca_sget >/dev/null || continue
            task=${sid#orca:}; task=${task%%/*}
            [ -n "$task" ] && [ "$(_n1_orca_sget "$(n1_orca_sentinel_path "$h" "$t")" N1_ORCA_TASK)" = "$task" ] || continue
        fi
        case "$sid" in
            orca:*) printf '%s: /n1:n1-queue --answer %s <answer>\n' "$t" "$t" ;;
            ?*) printf '%s: %s\n' "$t" "$(n1_bg_cmd attach "$sid")" ;;
        esac
    done < <(n1_queue_pending_rows "$file" 'awaiting-human|failed|pr|escalated')
}

n1_queue_dispatch_skips() {
    # Usage: n1_queue_dispatch_skips <events.jsonl> <run_id> — N1-309 (N1-287): one line per worker message the
    # runner skipped in this run because its dispatch id did not match the Runs row (dispatch_mismatch events; the
    # runner already sanitized the ids). A missing or unreadable file prints nothing.
    jq -rR --arg r "$2" 'fromjson? | select(.event == "dispatch_mismatch" and .run_id == $r)
        | "\(.ticket): skipped worker message (\(.reason))"' "$1" 2>/dev/null | sort -u
    return 0
}

n1_queue_cleanup_left() {
    # Usage: n1_queue_cleanup_left <events.jsonl> - N1-339: "<ticket>: <reason>" for each ticket whose last
    # ticket_cleanup event was not a success. A missing or unreadable file prints nothing.
    jq -rRn '[inputs | fromjson? | objects | select(.event == "ticket_cleanup")] | group_by(.ticket)[] | last
        | select(.outcome != "success") | "\(.ticket): \(.reason)"' "$1" 2>/dev/null
    return 0
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
    # Usage: n1_queue_escalation_text <overview.md> — first human-needed "## Escalations" entry, or empty.
    # N1-241: skips autonomous records that belong in ## Key Decisions / the Decision Ledger
    # (plan-review verdict, auto-decided). Fails closed: only these anchored shapes are skipped,
    # unknown text stays an escalation, and "[headless] <step>:" entries are never skipped.
    [ -f "$1" ] || return 0
    # An indented line directly after an entry (skipped or kept) is its continuation; a blank line
    # or a new heading ends it. Optional $2=last prints the newest human-needed entry instead.
    awk -v last="${2:-}" '/^## Escalations/{f=1;prev=0;next} /^## /{f=0;prev=0}
        f && !NF { prev = 0; next }
        f {
            if (prev && /^[[:space:]]+[^[:space:]]/) next
            prev = 1
            sub(/^[-*][[:space:]]*/,""); l = tolower($0)
            if (l !~ /^\[headless\] / && (l ~ /^[*]*plan[ -]review[*]*:? *[*]*(clean|fixed)([^a-z]|$)/ || l ~ /^(approach [a-z0-9]+ )?auto-decided([ (]|$)/ || l ~ /^\[auto(-decided)?\]/)) next
            if (last == "") { print; exit }
            out = $0
        }
        END { if (out != "") print out }' "$1"
}


n1_queue_digest() {
    # Usage: n1_queue_digest <n1-home> — one status line for the queue active in the last 24h,
    # preferring one with a ticket that needs you; prints nothing when none qualifies.
    # Reads <n1-home>/queue/*/events.jsonl (latest run per queue, latest event per ticket; non-JSON
    # lines are skipped). N1-333: also reads each queue.md's step and pid (local only: kill -0 and
    # /proc, no network, no writes); a queue whose runner is gone while step is run says "runner gone"
    # instead of "running <ids>", also after SIGKILL, which no trap can record.
    local f q qid gone=""
    for q in "$1"/queue/*/queue.md; do
        n1_queue_interrupted "$q" || continue
        qid=$(n1_read_frontmatter "$q" queue_id); gone="$gone${qid:-queue}"$'\n'
    done
    for f in "$1"/queue/*/events.jsonl; do [ -f "$f" ] && cat "$f"; done 2>/dev/null | jq -nrR --arg gone "$gone" '
        ($gone | split("\n")) as $g
        | [inputs | fromjson? | objects] | group_by(.queue) | map(
            .[-1] as $end
            | any($g[]; . == $end.queue) as $dead
            | ([.[] | select(.run_id == $end.run_id and .ticket != "" and .event != "worker_stopped" and .event != "stalled")] | group_by(.ticket) | map(.[-1])) as $t
            | ([$t[] | select(.event == "escalated" or .outcome == "escalated") | .ticket]) as $needs
            | ([$t[] | select(.event == "ticket_finished" and .outcome == "pr")] | length) as $pr
            | ([$t[] | select(.event == "ticket_finished" and .outcome == "failed")] | length) as $failed
            | ([$t[] | select(.event == "ticket_finished" and .outcome == "merged")] | length) as $merged
            | ([$t[] | select(.event == "ticket_started" or .event == "unblocked") | .ticket]) as $running
            | {needs: ($needs | length), ts: $end.ts,
               line: ("Queue \($end.queue): " + ([
                   (if $pr > 0 then "\($pr) PR" else empty end),
                   (if $merged > 0 then "\($merged) merged" else empty end),
                   (if ($needs | length) > 0 then "\($needs | length) needs you (\($needs | join(", ")))" else empty end),
                   (if $failed > 0 then "\($failed) failed" else empty end),
                   (if $dead then "runner gone" elif ($running | length) > 0 then "running \($running | join(", "))" else empty end),
                   (if $end.event == "queue_done" then "done" elif $end.event == "halted" then "halted" elif $end.event == "queue_interrupted" and ($dead | not) then "interrupted" else empty end)
               ] | if length == 0 then ["started"] else . end | join(", ")))})
        | map(select(.ts >= (now - 86400 | todate)))
        | sort_by([(.needs > 0), .ts]) | last | .line // empty' 2>/dev/null
    return 0
}

n1_queue_watch() {
    # Usage: n1_queue_watch <queue_dir> <run_id> <runner_pid> [from_line]
    # Session-side relay for one queue run. Every queue.pollSeconds, prints new escalated (full
    # mirrored question when present) / answer_delivered /
    # ticket_finished / ticket_comment / ticket_replan / stalled / worker_stopped (errored only, N1-393) / halted / queue_done
    # events in <queue_dir>/events.jsonl whose run_id is <run_id> (never queue id alone: a
    # relaunch appends to the same file).
    # Consumed-line count persists in <queue_dir>/.watch-<run_id>.<session>, so re-running the
    # identical command after a host timeout resumes with no gap and no replay. Without that
    # cursor it starts at line <from_line> (default: current end of file).
    # Final lines end with "Watch ended.": on halted, queue_done, or runner pid gone; the
    # cursor is removed and it returns 0. Otherwise it polls until killed.
    # ponytail: a watch killed with its session leaves its small cursor file behind; sweep if they pile up.
    # ponytail: escalation dedupe (ticket+reason) is in-memory; a watch restart resumes past consumed lines via the cursor, so no replay.
    local dir="$1" run="$2" pid="$3" from="${4:-}" events="$1/events.jsonl" q sid cursor seen total alive poll
    local ev t out pr s reason qbody qrender hint key relayed=""
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
            while IFS=$'\x1f' read -r ev t out pr s reason full; do
                case "$ev" in
                    escalated)
                        # N1-241: relay one escalation per ticket+reason (runner park/drain/restart
                        # can emit the same one twice); answer_delivered resets it for a re-ask.
                        key="$t"$'\t'"$out"$'\t'"$full"  # $full: untruncated reason, so the 300-char display cap never merges distinct escalations; $out: a terminal escalation (n1-start hint) is never swallowed by an earlier attach-hint one
                        if [ -n "$relayed" ] && grep -qxF -- "$key" <<<"$relayed"; then continue; fi
                        relayed=$(awk -F'\t' -v t="$t" '$1 != t' <<<"$relayed"; printf '%s' "$key")
                        # N1-55: a child in ask-mode mirrors its full question to .question-<ticket>.json.
                        # qrender is shared with the N1-60 fallback below so a packed-JSON reason
                        # renders identically to the live question file.
                        qrender='def s: tostring | gsub("[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\u061c\u00ad\u200b-\u200d\u2060-\u2064\ufeff\\x{E0000}-\\x{E007F}]"; " ") | .[:1000];
                                (.rationale // "" | s) as $r | (.recommended // "" | s) as $rec
                                | "  Q: \(.question | s)",
                                  (select($rec == "" and $r != "") | "  \($r)"),
                                  (((.alternatives | objects) // {}) as $alt | .options | arrays | .[:10] | .[] | "  - \(s)", ($alt[.]? // empty | s | select(. != "") | "      \(.)")),
                                  (select($rec != "") | "  Recommended: \($rec)\(if $r != "" then " — \($r)" else "" end)")'
                        qbody=""
                        case "$t" in ''|*[!A-Za-z0-9_-]*) ;; *) [ -f "$dir/.question-$t.json" ] && \
                            qbody=$(jq -r "$qrender" "$dir/.question-$t.json" 2>/dev/null) ;; esac
                        # N1-74: outcome=terminal means the session is drained and stopped (finalize's
                        # stopped-path escalate): attach would reach nothing, so hint n1-start instead.
                        if [ "$out" = terminal ]; then
                            hint="; resume: n1-start $t"
                        else
                            hint="${s:+; resume: $(n1_bg_cmd attach "$s")}"
                        fi
                        if [ -z "$qbody" ]; then
                            # N1-60: reason may hold the full mirrored question (packed JSON) once
                            # the question file is already gone; render it the same way, so the
                            # user still sees the full question instead of a generic wait message.
                            # SEC-4/CR-3: a real object-with-"question" check, not a '{' prefix guess.
                            qbody=$(printf '%s' "$reason" | jq -R "fromjson? | objects | select(has(\"question\")) | ($qrender)" 2>/dev/null)
                        fi
                        if [ -n "$qbody" ]; then
                            printf 'n1-queue %s: %s needs you (answer: /n1:n1-queue --answer %s "<text>"%s):\n%s\n' \
                                "$q" "$t" "$t" "$hint" "$qbody"
                        else
                            printf 'n1-queue %s: %s needs you: %s%s\n' "$q" "$t" "${reason:-waiting for an answer}" \
                                "${hint:+ (${hint#; })}"
                        fi ;;
                    answer_delivered|unblocked)
                        relayed=$(awk -F'\t' -v t="$t" '$1 != t' <<<"$relayed")
                        if [ "$ev" = answer_delivered ]; then printf 'n1-queue %s: %s answer delivered, resuming.\n' "$q" "$t"; fi ;;
                    ticket_comment)
                        printf 'n1-queue %s: %s has a new external ticket comment: %s\n' "$q" "$t" "$reason" ;;
                    ticket_replan)
                        printf 'n1-queue %s: %s re-planned after an external ticket change: %s\n' "$q" "$t" "$reason" ;;
                    stalled)
                        printf 'n1-queue %s: %s may be stalled (%s)\n' "$q" "$t" "$reason" ;;
                    worker_stopped)
                        # N1-393: only an errored stop needs a human; finished/other stop reasons stay silent.
                        case "$reason" in 'stopped (errored)'*)
                            printf 'n1-queue %s: %s worker stopped, needs attention (%s)\n' "$q" "$t" "$reason" ;; esac ;;
                    ticket_finished)
                        printf 'n1-queue %s: %s finished: %s%s%s\n' "$q" "$t" "$out" "${pr:+ $pr}" "${reason:+ ($reason)}" ;;
                    halted|queue_done)
                        [ "$ev" = halted ] && ev=halted || ev=finished
                        printf 'n1-queue %s: %s%s. Watch ended.\n' "$q" "$ev" "${reason:+: $reason}"
                        rm -f "$cursor"; return 0 ;;
                esac
            done < <(sed -n "$((seen + 1)),${total}p" "$events" | jq -rR --arg run "$run" '
                fromjson? | objects | select(.run_id == $run)
                | select(.event == "escalated" or .event == "answer_delivered" or .event == "unblocked" or .event == "ticket_comment" or .event == "ticket_replan" or .event == "stalled" or .event == "worker_stopped" or .event == "ticket_finished" or .event == "halted" or .event == "queue_done")
                | [.event, .ticket, .outcome, .pr, .session, .reason]
                | map(tostring | gsub("[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\u061c\u00ad\u200b-\u200d\u2060-\u2064\ufeff\\x{E0000}-\\x{E007F}]"; " ")) as $arr
                # N1-60 [CR-4]: a packed-question reason is already capped at write time
                # (escalate(): 2000 chars/field, <=10 options); the 300-cap here is only
                # for plain-text reasons and the other fields.
                | (($arr[5] | fromjson? | objects | has("question")) // false) as $packed
                | ($arr[0:5] | map(.[:300])) + [if $packed then $arr[5] else $arr[5][:300] end, $arr[5]]
                | join("\u001f")' 2>/dev/null)
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
    # Prints one tab-separated row per Plan row: Ticket State Step Elapsed Cost PR Attach Cleanup.
    # Live-overrides State for in-progress/awaiting-human rows from
    # `claude agents --json --all` via n1_queue_bg_state (same missing/failed degradation
    # it already applies; no second failure path).
    # N1-333: with step run and a dead runner pid (also after SIGKILL) an in-progress row reads runner-gone;
    # awaiting-human rows keep their state (--answer works without a runner).
    local file="$1" events="$2" agents_json now gone=""
    agents_json=$(bash -c "$(n1_bg_cmd agents)" 2>/dev/null)
    now=$(date +%s)
    n1_queue_interrupted "$file" && gone=1

    while IFS=$'\t' read -r num ticket repo n1h model status; do
        local state="$status" step="" elapsed="" cost="—" pr="" attach="" sid
        case "$status" in
            in-progress|awaiting-human)
                sid=$(n1_queue_session_id "$file" "$ticket")
                if [ -n "$sid" ] && [ "${sid#orca:}" = "$sid" ]; then  # N1-225: Orca rows keep their Plan status
                    local bgs; bgs=$(n1_queue_bg_state "$agents_json" "$sid")
                    case "$bgs" in
                        working) state=in-progress ;;
                        blocked) state=awaiting-human ;;
                        missing|failed) state="$bgs" ;;
                        done) : ;;  # runner hasn't finalized yet; keep the Plan status as-is
                    esac
                fi
                [ -n "$gone" ] && [ "$state" = in-progress ] && state=runner-gone
                step=$(n1_read_frontmatter "$n1h/memory/$ticket/overview.md" current_step)
                [ -n "$step" ] || step=$(n1_read_frontmatter "$n1h/memory/$ticket/overview.md" step)
                local started; started=$(n1_queue_session_started "$file" "$ticket")
                if [ -n "$started" ]; then
                    local started_epoch
                    started_epoch=$(date -u -d "$started" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
                    [ "$started_epoch" -gt 0 ] && elapsed=$(n1_fmt_elapsed "$((now - started_epoch))")
                fi
                [ "$state" = awaiting-human ] && [ -n "$sid" ] && attach=$(n1_bg_cmd attach "$sid")
                ;;
            pr|failed|deferred|escalated|stopped)
                local dur; dur=$(_n1_queue_event_duration "$events" "$ticket")
                [ -n "$dur" ] && elapsed=$(n1_fmt_elapsed "$dur")
                # N1-268: the Runs Outcome is the only place a merge is recorded (Plan status stays pr).
                case "$status" in pr|failed|stopped) [ "$(_n1_queue_run_outcome "$file" "$ticket")" = merged ] && state=merged ;; esac
                if [ "$status" = pr ]; then
                    pr=$(n1_queue_child_pr_url "$n1h/memory/$ticket/overview.md")
                    [ -n "$pr" ] || pr=$(_n1_queue_run_pr "$file" "$ticket")
                else
                    step=$(n1_read_frontmatter "$n1h/memory/$ticket/overview.md" step)
                    [ "$step" = escalated ] && step=$(_n1_queue_escalated_step "$n1h/memory/$ticket/overview.md")
                fi
                ;;
        esac
        local cln; cln=$(sed -n 's/^- \*\*Cleanup:\*\* //p' "$n1h/memory/$ticket/overview.md" 2>/dev/null | head -1)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ticket" "$state" "$step" "$elapsed" "$cost" "$pr" "$attach" "$(_n1_queue_sanitize_cell "$cln")"
    done < <(awk -F'|' '{ for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) } $2 ~ /^[0-9]+$/ && NF >= 9 { printf "%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $5, $6, $7, $8 }' "$file")
}

n1_queue_beacon_lines() {
    # Usage: n1_queue_beacon_lines <queue.md> — N1-315: "<ticket>\t<phase>\t<age>\t<stalled?|>" per in-progress row
    # with a worker progress beacon (<queue-dir>/.hb-<ticket> = "<epoch>\t<phase>", written by the runner;
    # .stall-<ticket> = the runner flagged it). Prints nothing when no row has a beacon.
    local d now num t at ph
    d=$(dirname "$1"); now=$(date +%s)
    while IFS=$'\t' read -r num t _ _ _ _; do
        at=""; ph=""
        IFS=$'\t' read -r at ph 2>/dev/null < "$d/.hb-$t" || true
        case "$at" in ''|*[!0-9]*)
            # Never beaconed: a stall-flagged row still shows, aged from the launch lock like the runner does.
            [ -e "$d/.stall-$t" ] || continue
            at=$(stat -c %Y "$d/.launch-$num" 2>/dev/null || stat -f %m "$d/.launch-$num" 2>/dev/null) || continue
            case "$at" in ''|*[!0-9]*) continue ;; esac
            ph="" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$t" "${ph:-unknown}" "$(n1_fmt_elapsed "$((now - at))")" "$([ -e "$d/.stall-$t" ] && echo 'stalled?')"
    done < <(n1_queue_pending_rows "$1" 'in-progress')
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

_n1_queue_run_outcome() {
    # Usage: _n1_queue_run_outcome <queue.md> <ticket> — Outcome cell of the ticket's last Runs row (N1-268).
    awk -F'|' -v tk="$2" '/^## Runs/ { r = 1; next } /^## / { r = 0 }
        r && index($0, "| " tk " |") == 1 { o = $5 }
        END { gsub(/^[[:space:]]+|[[:space:]]+$/, "", o); print o }' "$1"
}

n1_queue_runs_outcome() {
    # Usage: n1_queue_runs_outcome <queue.md> <ticket> <outcome> [pr-url] — N1-268: set the Outcome (and, when given,
    # the PR) cell of the ticket's last Runs row. The one writer for merged/stopped (runner chain, settle, --stop,
    # --status reconcile). Callers pass a PR URL only after n1_queue_pr_state answered MERGED (shape-checked).
    # Non-zero (file untouched) when the ticket has no Runs row: reconcile must not record a merge it could not store.
    local tmp; tmp=$(mktemp "$1.XXXXXX") || return 1
    awk -v tk="$2" -v oc="$3" -v pr="${4:-}" '
    { lines[NR] = $0; n = NR }
    /^## Runs/ { rs = NR }
    END {
        for (i = n; rs && i > rs; i--) if (index(lines[i], "| " tk " |") > 0) {
            split(lines[i], c, "|"); c[5] = " " oc " "; if (pr != "") c[6] = " " pr " "; out = ""
            for (j = 1; j <= 7; j++) out = out c[j] "|"
            lines[i] = out; hit = 1; break
        }
        for (i = 1; i <= n; i++) print lines[i]
        exit hit ? 0 : 1
    }' "$1" > "$tmp" && mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

n1_queue_attested_pr() {
    # Usage: n1_queue_attested_pr <queue.md> <ticket> <n1-home> — N1-268: the PR URL to trust for a merge record.
    # overview.md pr_url only when finalize stamped it for this queue run (queue_run_id == the queue's run_id: ticket
    # memory outlives runs and a child writes its own overview.md), else the Runs PR cell.
    local rid ov="$3/memory/$2/overview.md" url=""
    rid=$(n1_read_frontmatter "$1" run_id)
    [ -n "$rid" ] && [ "$(n1_read_frontmatter "$ov" queue_run_id 2>/dev/null)" = "$rid" ] && url=$(n1_queue_child_pr_url "$ov")
    [ -n "$url" ] || url=$(_n1_queue_run_pr "$1" "$2")
    printf '%s\n' "$url"
}

n1_queue_reconcile() {
    # Usage: n1_queue_reconcile <queue.md> — N1-268, --status: with no live runner (a live one records merges itself
    # on settle), a pr/failed/stopped row whose PR merged since gets Runs Outcome merged, Plan status pr and one
    # ticket_finished outcome=merged event. PR URL: overview.md pr_url only when finalize stamped it for this queue run
    # (queue_run_id == the queue's run_id: ticket memory outlives runs, so an older run's merged PR must not count),
    # else the Runs PR cell (overview.md final_outcome never says merged). Never merges, chains or releases tags; an
    # unreadable PR state, or a ticket without a Runs row, leaves the row.
    local q="$1" evf qid rid num ticket repo n1h model status url
    n1_queue_runner_alive "$(n1_read_frontmatter "$q" pid)" "$q" && return 0
    evf="$(dirname "$q")/events.jsonl"; qid=$(n1_read_frontmatter "$q" queue_id); rid=$(n1_read_frontmatter "$q" run_id)
    while IFS=$'\t' read -r -u 3 num ticket repo n1h model status; do
        [ "$(_n1_queue_run_outcome "$q" "$ticket")" = merged ] && continue
        url=$(n1_queue_attested_pr "$q" "$ticket" "$n1h")
        [ "$(n1_queue_pr_state "$url")" = MERGED ] || continue
        n1_queue_runs_outcome "$q" "$ticket" merged "$url" || continue
        [ "$status" = pr ] || n1_queue_row_status "$q" "$num" pr
        n1_queue_event "$evf" "$qid" "$rid" ticket_finished ticket="$ticket" outcome=merged pr="$url"
        printf 'reconciled: %s merged\n' "$ticket"
    done 3< <(n1_queue_pending_rows "$q" 'pr|failed|stopped')
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

n1_queue_notify_check() {
    # Usage: n1_queue_notify_check — prints a warning line when the configured
    # queue.notify backend cannot deliver (NP-216: silent notification gaps).
    # Prints nothing when the backend is usable. Mirrors n1_notify's backend logic.
    local backend val
    backend=$(n1_queue_val notify)
    case "${backend:-desktop}" in
        none) ;;
        command)
            val=$(n1_queue_val notifyCommand)
            [ -n "$val" ] || echo "Warning: queue.notify=command but queue.notifyCommand is not set; notifications will be skipped." ;;
        ntfy)
            val=$(n1_queue_val ntfyTopic)
            [ -n "$val" ] || echo "Warning: queue.notify=ntfy but queue.ntfyTopic is not set; notifications will be skipped." ;;
        *)
            if ! command -v notify-send >/dev/null 2>&1 && ! command -v osascript >/dev/null 2>&1 && [ -z "$(n1_powershell_path)" ]; then
                echo "Warning: queue.notify=desktop but no desktop notifier (notify-send/osascript/powershell.exe) was found; notifications will be skipped."
            fi
            ;;
    esac
    return 0
}

n1_notify() {
    # Usage: n1_notify <needs-you|done|info> <text> — best-effort out-of-session alert.
    # Backend from queue.notify: desktop (default) | ntfy (queue.ntfyTopic) | command
    # (queue.notifyCommand gets {"ts","kind","text"} on stdin) | none. Never fails the caller.
    local kind="$1" text="$2" title="N1 queue: $1" backend val
    [ "$kind" != needs-you ] || n1_orca_unread_main "$text"   # N1-226: also mark the main-checkout Orca card
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
                -d "$text" "$val" </dev/null >/dev/null 2>&1 ;;
        *)
            n1_desktop_notify "$title" "$text" \
                || echo "n1_notify: no desktop notifier available; skipped ($kind: $text)" >&2 ;;
    esac
    return 0
}

n1_story_convert_decision() {
    # Usage: n1_story_convert_decision <tracker_type> <children: has|none|unknown> <convert_mcp>
    # N1-119: action for a Story at n1-start intake. Prints story | convert | single:<reason>.
    # Anything but children=none keeps the Story: a failed child search never converts.
    local tracker
    tracker=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [ "$2" = "none" ] || { printf 'story'; return 0; }
    case "$tracker" in
        youtrack) printf 'single:youtrack' ;;
        jira) if [ -n "$3" ]; then printf 'convert'; else printf 'single:no-jc-mcp'; fi ;;
        *) printf 'single:unsupported' ;;
    esac
}
