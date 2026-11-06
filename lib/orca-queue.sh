#!/usr/bin/env bash
# N1-225: Orca orchestration backend for n1-queue: backend choice, orchestration CLI wrappers (coordinator side),
# the per-ticket identity sentinel and the child contract (worker_done, ask).
# Requires lib/config.sh (n1_orca, n1_home, n1_config_val, n1_session_id). n1_queue_backend and
# n1_orca_worker_done also need lib/queue.sh. Every Orca call goes through n1_orca ("$ORCA_CLI_COMMAND ... --json").
# Receipt JSON shapes of run-create/task-create/worker-start/check/ask are unverified (orchestration is
# experimental, flags drift): parsers try several paths and fail closed on a missing or unsafe id.
declare -F n1_read_frontmatter >/dev/null || source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/frontmatter.sh"

_n1_orca_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$ ]]; }

n1_queue_backend() {
    # Usage: n1_queue_backend — orca | bg. queue.backend auto (default) and orca pick orca only when the Orca
    # runtime is reachable; bg always picks bg. ORCA_CLI_COMMAND unset: bg without any subprocess (AC5).
    [ -n "${ORCA_CLI_COMMAND:-}" ] && [ "$(n1_queue_val backend)" != bg ] && n1_orca_active && { echo orca; return 0; }
    echo bg
}

n1_queue_max_concurrent() {
    # Usage: n1_queue_max_concurrent — N1-303: the concurrency a plan pins as queue.md max_concurrent. 1 on the
    # bg backend (sequential), else queue.maxConcurrent (positive integer, fallback 1).
    local m
    if [ "$(n1_queue_backend)" = bg ]; then echo 1; return 0; fi
    m=$(n1_queue_val maxConcurrent); [[ "$m" =~ ^[1-9][0-9]*$ ]] || m=1
    echo "$m"
}

n1_orca_run_create() {
    # Usage: n1_orca_run_create <queue-id> — prints the new Run id; non-zero when orchestration is unavailable
    # (CLI missing, feature disabled, unknown command, no usable id in the receipt).
    local out id a=(orchestration run-create --objective "n1-queue $1")
    [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && a+=(--from "$ORCA_TERMINAL_HANDLE")
    out=$(N1_ORCA_TIMEOUT=30 n1_orca "${a[@]}") || return 1
    id=$(jq -r '.result.run.id // .result.id // empty' <<<"$out" 2>/dev/null)
    _n1_orca_id "$id" || return 1
    printf '%s' "$id"
}

n1_orca_run_use() {
    # Usage: n1_orca_run_use <run> — rebind an existing Run after a runner or Orca restart.
    N1_ORCA_TIMEOUT=30 n1_orca orchestration run-use --id "$1" >/dev/null
}

n1_orca_coord_open() {
    # Usage: n1_orca_coord_open <queue-id> — N1-270: open the runner's own Orca terminal to coordinate the Run. Orca
    # nudges a Run's coordinator terminal whenever a worker sends ("You have 1 orchestration message ..."), heartbeats
    # included, and a coordinator must be a terminal (no_active_sender_terminal). The terminal runs cat >/dev/null: a
    # nudge is read and discarded, never executed. Prints the handle; non-zero on a CLI failure or a missing or unsafe
    # handle (the caller keeps the launching terminal). The receipt shape is unverified: several paths are tried.
    local out h
    out=$(N1_ORCA_TIMEOUT=30 n1_orca terminal create --title "n1-queue coordinator $1" --command 'cat >/dev/null') || return 1
    h=$(jq -r '.result.terminal.handle // .result.handle // .result.id // empty' <<<"$out" 2>/dev/null)
    _n1_orca_id "$h" || return 1
    printf '%s' "$h"
}

n1_orca_coord_close() {
    # Usage: n1_orca_coord_close <handle> — close a coordinator terminal opened by n1_orca_coord_open. Best-effort.
    _n1_orca_id "${1:-}" && N1_ORCA_TIMEOUT=30 n1_orca terminal close --terminal "$1" >/dev/null 2>&1
    return 0
}

n1_orca_task_create() {
    # Usage: n1_orca_task_create <run> <ticket> — prints the task id. The spec is the child's prompt; it names the
    # skill in words so it works whether or not a slash command still resolves after Orca's preamble.
    # --deps is always empty: same-plan blockers stay merge-gated held rows (N1-225 decision).
    local out id
    out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration task-create --run "$1" --task-title "$2" --deps '[]' \
        --spec "Invoke the n1-start skill for ticket $2 (equivalent to /n1:n1-start $2). Do not send heartbeat messages; liveness comes from Orca worker state, so send only worker_done and ask when needed. The Stop hook sends worker_done once the whole run is over; an open PR alone is not the end.")|| return 1
    id=$(jq -r '.result.task.id // .result.id // empty' <<<"$out" 2>/dev/null)
    _n1_orca_id "$id" || return 1
    printf '%s' "$id"
}

n1_orca_worker_start() {
    # Usage: n1_orca_worker_start <run> <task> <ticket> <repo> <model> [existing-worktree] — prints the dispatch id
    # (exit 0), else "orca-launch:<failedStage>" (exit 1). A launch rejected for its model is retried once without
    # --model (row models are aliases; Orca takes opaque provider ids). Any other failure is final: Orca forbids blind
    # relaunch. N1-271: with an existing worktree (n1_orca_worktree_resumable) the worker starts there
    # (--worktree path:<abs>, no --name: nothing new is created, so Orca has nothing to rename).
    # N1-291: with N1_STORY_BRANCH set, a new worktree gets --base-branch origin/$N1_STORY_BRANCH.
    local model="${5:-}" out id why rc
    local a=(orchestration worker-start --run "$1" --task "$2" --worktree new-top-level --name "$3" --repo "path:$4" --agent claude)
    [ -z "${6:-}" ] || a=(orchestration worker-start --run "$1" --task "$2" --worktree "path:$6" --repo "path:$4" --agent claude)
    # N1-291: a story-mode new worktree starts from the story tip (caller env N1_STORY_BRANCH, runner-validated);
    # --base-branch is creation-only, so the path: resume never gets it. The child's Adopt Checkout re-syncs anyway.
    [ -n "${6:-}" ] || [ -z "${N1_STORY_BRANCH:-}" ] || a+=(--base-branch "origin/$N1_STORY_BRANCH")
    out=$(N1_ORCA_TIMEOUT=180 n1_orca "${a[@]}" ${model:+--model "$model"}); rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$model" ] && jq -r '.error.message // empty' <<<"$out" 2>/dev/null | grep -qi model; then
        echo "n1-queue: worker-start rejected model '$model' for $3; retrying without --model" >&2
        out=$(N1_ORCA_TIMEOUT=180 n1_orca "${a[@]}")
    fi
    id=$(jq -r '.result.dispatch.id // .result.dispatchId // .result.id // empty' <<<"$out" 2>/dev/null)
    if jq -e '.ok == true' <<<"$out" >/dev/null 2>&1 && _n1_orca_id "$id"; then printf '%s' "$id"; return 0; fi
    why=$(jq -r '.error.data.failedStage // .result.failedStage // .error.code // empty' <<<"$out" 2>/dev/null | tr -cd 'A-Za-z0-9_.-')
    printf 'orca-launch:%s' "${why:-cli-error}"
    return 1
}

n1_orca_check() {
    # Usage: n1_orca_check <run> <wait-seconds> — one coordinator inbox batch; blocks up to wait-seconds
    # (an empty batch is a checkpoint, not a failure). An Orca whose --types rejects heartbeat is retried once
    # without it (N1-282); any other failure passes through unchanged.
    local out rc t=$(( $2 * 1000 )) w=$(( $2 + 30 ))
    out=$(N1_ORCA_TIMEOUT=$w n1_orca orchestration check --run "$1" --wait \
        --types worker_done,escalation,question,heartbeat --timeout-ms "$t"); rc=$?
    if [ "$rc" -ne 0 ] && jq -r '.error.message // empty' <<<"$out" 2>/dev/null | grep -qi 'Invalid --types'; then
        echo "n1-queue: Orca rejected --types heartbeat; retrying without it" >&2
        out=$(N1_ORCA_TIMEOUT=$w n1_orca orchestration check --run "$1" --wait \
            --types worker_done,escalation,question --timeout-ms "$t"); rc=$?
    fi
    printf '%s\n' "$out"
    return "$rc"
}

n1_orca_events() {
    # Usage: n1_orca_events <check-json> — "<type>\t<task-id>\t<message-id>\t<dispatch-id>[\t<text>]" per message. Orca 1.4.243
    # carries taskId/dispatchId only inside "payload", a JSON string; top-level fields stay as a fallback. A malformed
    # or non-object payload falls back too, and a non-string id reads empty (@tsv errors on an object and would drop
    # the rest of the batch), so one bad message never drops the batch. A message with no task id is dropped (an empty
    # column would collapse under the consumer's read). An empty type/message/dispatch is emitted as "-" (tab is
    # whitespace to read, so an empty column would shift the rest); the consumer maps "-" back to empty. Ids are untrusted: the consumer binds the dispatch to the Runs row.
    # N1-359: an escalation whose payload carries a string stopReason is Orca's "worker stopped without reporting"
    # notice, emitted as type "escalation-stop" with text "stopped (<stopReason>): <body, else subject>"; a plain
    # escalation's text is its subject. The text is untrusted: control/format chars become spaces, then it is cut to
    # 300 chars. The 5th column is omitted when the text is empty (the consumer's last read variable then reads empty).
    # N1-315: a heartbeat's text is its payload phase (hook-sent progress beacon), cut to 64 chars.
    jq -r 'def str: if type == "string" then . else "" end;
        def strip: gsub("[\u0000-\u001f\u007f-\u009f\u00ad\u061c\u200b-\u200f\u2028\u2029\u202a-\u202e\u2060-\u2069\ufeff\\x{E0000}-\\x{E007F}]"; " ");
        (.result.messages // .result.batch // .result.items // [])[]?
        | (.payload | if type == "string" then (try fromjson catch {}) else . end
            | if type == "object" then . else {} end) as $p
        | ($p.taskId // .taskId // .task_id // .task.id // "" | str) as $tid
        | select($tid != "")
        | ($p.stopReason // "" | str) as $stop
        | (.type // .messageType // "") as $t0
        | (if $t0 == "escalation" and $stop != "" then "escalation-stop" else $t0 end) as $ty
        | (if $ty == "escalation-stop" then
               "stopped (" + $stop + "): " + ([.body, .subject] | map(str | select(. != "")) | .[0] // "")
           elif $ty == "escalation" then (.subject | str)
           elif $ty == "heartbeat" then ($p.phase // "" | str | .[:64])
           else "" end | strip | .[:300]) as $x
        | ([$ty, $tid, (.id // .messageId // ""),
           ($p.dispatchId // .dispatchId // .dispatch_id // .dispatch.id // "" | str)]
           | map(if . == "" then "-" else . end) | @tsv)
        # The text is appended outside @tsv: strip leaves no tab/newline in it, and @tsv would double its backslashes.
        + (if $x != "" then "\t" + $x else "" end)' <<<"$1" 2>/dev/null
    return 0
}

n1_orca_ack() {
    # Usage: n1_orca_ack <run> <check-json> — acknowledge the batch so check stops replaying it. Best-effort.
    local d; d=$(jq -r '.result.deliveryId // .result.delivery_id // .result.delivery.id // empty' <<<"$2" 2>/dev/null)
    _n1_orca_id "$d" && n1_orca orchestration check --run "$1" --ack "$d" >/dev/null
    return 0
}

n1_orca_liveness() {
    # Usage: n1_orca_liveness <run> — "<dispatch>\t<task>\t<live|unverifiable|exited>\t<done|>\t<stage-detail|>" per worker; non-zero
    # when the list is unreadable. Orca reports liveness as {"verdict":..,"reason":..} (a bare string is still accepted);
    # a missing or non-string verdict reads unverifiable: only positive proof of exit settles a worker by liveness.
    # Field 4 (N1-281) is "done" for a durable terminal state only: workerState succeeded|failed, dispatchStatus
    # completed, or projection.nextAction.kind release. A running or unknown state is empty and never settles.
    # Field 5 (N1-333) is projection.stage.detail when it is a string (e.g. terminal_missing: Orca lost the worker's
    # terminal), else empty. Every consumer indexes columns with awk -F'\t', so the appended column is additive.
    # ponytail: first page only (default limit 100, newest first, --run scoped); follow result.page.nextCursor if a Run ever outgrows it.
    local out; out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration worker-list --run "$1") || return 1
    # Only an ok receipt with an array-shaped worker collection is a readable list; anything else is non-zero.
    jq -r '(.result.workers // .result.dispatches // .result.items) as $w
        | if .ok == true and ($w | type) == "array" then $w[]
            | [(.dispatchId // .dispatch.id // .id // ""), (.taskId // .task.id // ""),
               (.projection.liveness | if type == "object" then .verdict else . end
                    | if type == "string" then . else "unverifiable" end),
               (if .workerState == "succeeded" or .workerState == "failed" or .dispatchStatus == "completed"
                    or ((.projection.nextAction | if type == "object" then .kind else null end) == "release")
                then "done" else "" end),
               (.projection.stage | if type == "object" then .detail else null end | if type == "string" then . else "" end)] | @tsv
          else error("unreadable worker list") end' <<<"$out" 2>/dev/null
}

n1_orca_release() {
    # Usage: n1_orca_release <dispatch> — worker-release (idempotent). Best-effort.
    _n1_orca_id "${1:-}" && n1_orca orchestration worker-release --dispatch "$1" >/dev/null 2>&1
    return 0
}

n1_orca_terminal_of() {
    # Usage: n1_orca_terminal_of <run> <dispatch> — N1-268: the worker's own terminal handle (worker-list
    # resource.terminalHandle), rc 0. N1-333: rc 2 = nothing to close: a readable list (ok receipt, worker array) where
    # the dispatch is absent or Orca marks it projection.stage.detail terminal_missing. rc 1 (fail closed) otherwise:
    # an unreadable list or non-ok receipt, a paginated list (page.hasMore/nextCursor) missing the dispatch, or a listed
    # worker with no or an unsafe handle.
    local out h
    out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration worker-list --run "$1") || return 1
    h=$(jq -r --arg d "$2" '(.result.workers // .result.dispatches // .result.items) as $w
        | if .ok == true and ($w | type) == "array" then
            ([$w[] | select((.dispatchId // .dispatch.id // .id) == $d)] | first) as $r
            | if $r == null then
                (if .result.page.hasMore == true or (.result.page.nextCursor // null) != null
                 then error("incomplete worker list") else "A" end)
              elif ($r.projection.stage | if type == "object" then .detail else null end) == "terminal_missing" then "A"
              else "H" + ($r.resource.terminalHandle // "" | strings) end
          else error("unreadable worker list") end' <<<"$out" 2>/dev/null) || return 1
    [[ "$h" == A ]] && return 2   # status prefix: A = nothing to close, H<handle> = a handle to validate
    h=${h#H}
    _n1_orca_id "$h" || return 1
    printf '%s' "$h"
}

n1_orca_terminal_close() {
    # Usage: n1_orca_terminal_close <handle> — N1-268: close exactly one terminal (never --worktree ... --all).
    _n1_orca_id "${1:-}" || return 1
    N1_ORCA_TIMEOUT=30 n1_orca terminal close --terminal "$1" >/dev/null
}

n1_orca_worktree_taken() {
    # Usage: n1_orca_worktree_taken <ticket> — true when an Orca worktree folder is already named <ticket>. The
    # identity loader keys on that folder name; if Orca deduplicated a clashing --name (e.g. T-1-2), the child would
    # start without its sentinel (merge guard off). An unreadable list reads "taken" (fail closed: the row fails, no worker starts blind).
    local out; out=$(N1_ORCA_TIMEOUT=30 n1_orca worktree list) || return 0
    jq -e --arg n "$1" 'if (.result.worktrees | type) == "array" then any(.result.worktrees[]; (.path | split("/") | last) == $n) else true end' <<<"$out" >/dev/null 2>&1
    [ $? -ne 1 ]
}

n1_orca_worktree_resumable() {
    # Usage: n1_orca_worktree_resumable <ticket> <overview.md> <repo> — N1-271: prints the path of the ticket's existing Orca
    # worktree (exit 0) only when overview.md's workspace_path is that worktree and exactly one Orca worktree folder is
    # named <ticket> (the identity loader keys on that folder name, which a reused worktree keeps). A missing overview,
    # an empty workspace_path, an unreadable list, zero or several matches, a path mismatch, or a worktree whose git
    # common dir is not <repo>'s (SEC-2): exit 1 (the caller
    # keeps orca-worktree-name-taken, fail closed).
    local ws out wt rwt rws
    [ -f "$2" ] || return 1
    ws=$(n1_read_frontmatter "$2" workspace_path)
    [ -n "$ws" ] || return 1
    out=$(N1_ORCA_TIMEOUT=30 n1_orca worktree list) || return 1
    wt=$(jq -r --arg n "$1" 'if (.result.worktrees | type) == "array"
        then [.result.worktrees[] | .path | strings | select(split("/") | last == $n)] | if length == 1 then .[0] else empty end
        else empty end' <<<"$out" 2>/dev/null)
    [ -n "$wt" ] || return 1
    rwt=$(realpath -m -- "$wt" 2>/dev/null); rws=$(realpath -m -- "$ws" 2>/dev/null)
    [ -n "$rwt" ] && [ "$rwt" = "$rws" ] || return 1   # empty realpath on both sides must not match
    rwt=$(_n1_orca_common "$wt"); [ -n "$rwt" ] && [ -n "${3:-}" ] && [ "$rwt" = "$(_n1_orca_common "${3:-}")" ] || return 1   # same repo as the row
    printf '%s' "$wt"
}

n1_orca_usage_stalled() {
    # Usage: n1_orca_usage_stalled <ticket> — N1-267: true while the ticket's Orca worker waits on the Claude usage limit:
    # in the newest transcript of its worktree (Orca folder name == ticket), the last "Usage limit reached" system notice
    # comes after the last user/assistant entry. A new user/assistant entry ends the stall (the reset time in the notice
    # is local, dateless and not parsed). Any failure reads "not stalled" so time keeps being charged. The transcript is
    # untrusted: only matched, never printed. Claude names a project dir after its cwd, every non-alphanumeric -> '-'.
    # ponytail: one worktree list call per in-progress row per tick; cache the path in .wt-<ticket> if it shows up in profiling.
    local root="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" out wt f
    _n1_orca_id "${1:-}" && [ -d "$root" ] || return 1
    out=$(N1_ORCA_TIMEOUT=30 n1_orca worktree list) || return 1
    wt=$(jq -r --arg n "$1" '[.result.worktrees[]? | .path | strings | select(split("/") | last == $n)][0] // empty' <<<"$out" 2>/dev/null)
    [ -n "$wt" ] || return 1
    f=$(ls -t "$root/$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')"/*.jsonl 2>/dev/null | head -1)
    [ -n "$f" ] || return 1
    tail -n 50 "$f" | jq -nRe '[inputs | fromjson? // empty | objects] | to_entries
        | ([.[] | select(.value.type == "user" or .value.type == "assistant") | .key] | max // -1) as $w
        | ([.[] | select(.value.type == "system" and .value.subtype == "informational"
               and ((.value.content | strings | startswith("Usage limit reached")) // false)) | .key] | max // -1) as $m
        | $m > $w' >/dev/null 2>&1
}

# ---- Identity sentinel (N1-225) ----
# worker-start has no env flag, so an Orca child would run as an interactive session (merge guard off, a question
# TUI nobody answers). The runner writes $N1_HOME/queue/sentinels/<ticket>.env before worker-start; SessionStart
# persists it for Bash commands via CLAUDE_ENV_FILE and every hook loads it into its own process.
N1_ORCA_SENTINEL_KEYS="N1_HEADLESS N1_UNATTENDED N1_QUEUE_RUN_ID N1_QUEUE_TAG N1_QUEUE_DIR N1_PARENT_SESSION_ID N1_ORCA_REPO N1_ORCA_RUN N1_ORCA_TASK N1_ORCA_DISPATCH N1_ORCA_RESUME N1_STORY_ID N1_STORY_BRANCH"

n1_orca_sentinel_path() { printf '%s/queue/sentinels/%s.env' "$1" "$2"; }   # <n1-home> <ticket>
# <ticket> — fixed, git-independent pointer to the ticket's N1 home: the loader never resolves the home through git
# config, which a child can change (git remote set-url). ponytail: keyed by ticket only; ticket ids carry a project prefix.
n1_orca_home_ptr() { printf '%s/.n1/orca-home/%s' "$HOME" "$1"; }

n1_orca_identity_guard() {
    # Usage: n1_orca_identity_guard <n1-home> <ticket> [fallback-run] — N1-271: the identity file says whether a worker
    # may be live. Prints its task (empty when no identity file). Non-zero (fail closed) when the identity lacks task or
    # run, the worker list is unreadable, or a listed worker for the task is neither exited nor done.
    local idf task run L
    idf=$(n1_orca_sentinel_path "$1" "$2")
    [ -n "$1" ] && [ -e "$idf" ] || return 0
    task=$(_n1_orca_sget "$idf" N1_ORCA_TASK); run=$(_n1_orca_sget "$idf" N1_ORCA_RUN)
    [ -n "$run" ] || run="$3"
    [ -n "$task" ] && [ -n "$run" ] && L=$(n1_orca_liveness "$run" 2>/dev/null) || return 1
    ! awk -F'\t' -v k="$task" '$2 == k && $3 != "exited" && $4 != "done" { f = 1 } END { exit !f }' <<< "$L" || return 1
    printf '%s' "$task"
}

n1_orca_sentinel_write() {
    # Usage: n1_orca_sentinel_write <n1-home> <ticket> <repo> <queue-run-id> <orca-run> <task>
    # Runner side, before worker-start: KEY=value lines (same env as a bg child's --settings), mode 600, atomic.
    local f t
    f=$(n1_orca_sentinel_path "$1" "$2")
    mkdir -p "${f%/*}" && t=$(mktemp "$f.XXXXXX") || return 1
    chmod 600 "$t"
    {
        printf 'N1_HEADLESS=1\nN1_UNATTENDED=ask\n'
        printf 'N1_QUEUE_RUN_ID=%s\nN1_QUEUE_TAG=%s\nN1_QUEUE_DIR=%s\nN1_PARENT_SESSION_ID=%s\n' \
            "$4" "${N1_QUEUE_TAG:-}" "${N1_QUEUE_DIR:-}" "$(n1_session_id 2>/dev/null)"
        # N1-291: story-mode child only (runner prefix-assigns both); a non-story file is unchanged.
        [ -z "${N1_STORY_BRANCH:-}" ] || printf 'N1_STORY_ID=%s\nN1_STORY_BRANCH=%s\n' "${N1_STORY_ID:-}" "$N1_STORY_BRANCH"
        printf 'N1_ORCA_REPO=%s\nN1_ORCA_RUN=%s\nN1_ORCA_TASK=%s\n' "$3" "$5" "$6"
    } > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
    rm -f "${f%.env}.beacon"   # N1-315: a retry or resume must not inherit the previous attempt's phase stamp
    t=$(n1_orca_home_ptr "$2"); mkdir -p "${t%/*}" && printf '%s\n' "$1" > "$t"
}

n1_orca_sentinel_set() {
    # Usage: n1_orca_sentinel_set <n1-home> <ticket> <KEY> <value> — append one whitelisted key (last wins);
    # the runner adds N1_ORCA_DISPATCH once worker-start returns.
    case " $N1_ORCA_SENTINEL_KEYS " in *" $3 "*) ;; *) return 1 ;; esac
    printf '%s=%s\n' "$3" "${4//$'\n'/}" >> "$(n1_orca_sentinel_path "$1" "$2")"
}

_n1_orca_sget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }   # <file> <whitelisted KEY>; last wins

n1_orca_sentinel_rm() {
    # Usage: n1_orca_sentinel_rm <n1-home> <ticket> [task] — with a task, only that attempt's sentinel goes
    # (a deferred retry already wrote a new one under the same ticket).
    local f; f=$(n1_orca_sentinel_path "$1" "$2")
    [ -z "${3:-}" ] || [ "$(_n1_orca_sget "$f" N1_ORCA_TASK)" = "$3" ] || return 0
    [ "$(head -1 "$(n1_orca_home_ptr "$2")" 2>/dev/null)" != "$1" ] || rm -f "$(n1_orca_home_ptr "$2")"
    rm -f "$f" "${f%.env}.sent" "${f%.env}.beacon" "${f%/*/*}/sessions/$2".*
}

n1_orca_unsettled() {
    # Usage: n1_orca_unsettled <queue.md> — N1-268: "<num>\t<ticket>\t<n1-home>\t<task>\t<dispatch>" per Orca worker of
    # the queue whose identity file still names its Runs-row task (settle removes it, so these are unsettled).
    # The last Plan row per ticket wins (a deferred retry reuses the ticket).
    local num ticket repo n1h model status sid task
    while IFS=$'\t' read -r num ticket repo n1h model status; do
        sid=$(n1_queue_session_id "$1" "$ticket")
        case "$sid" in orca:*/*) task="${sid#orca:}"; task="${task%%/*}" ;; *) continue ;; esac
        [ "$(_n1_orca_sget "$(n1_orca_sentinel_path "$n1h" "$ticket")" N1_ORCA_TASK)" = "$task" ] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$num" "$ticket" "$n1h" "$task" "${sid#*/}"
    done < <(n1_queue_pending_rows "$1" 'in-progress|awaiting-human|pr|failed|escalated' | awk -F'\t' '{ r[$2] = $0 } END { for (k in r) print r[k] }' | sort -n)
}

n1_orca_stop_worker() {
    # Usage: n1_orca_stop_worker <queue.md> <num> <ticket> <n1-home> <task> <dispatch> <orca-run> — N1-268, n1-queue
    # --stop only (after user confirmation). A PR merged for this queue run (n1_queue_attested_pr) is recorded merged;
    # otherwise the row is recorded stopped (Plan + Runs + event). Either way the worker's own terminal is closed
    # first unless it is proven settled, then the worker is released and its identity removed. N1-333: a worker whose
    # terminal Orca reports gone (absent from a readable list, or terminal_missing) has nothing to close. An unreadable
    # list, a missing or unsafe handle, or a failed close keeps the identity (non-zero, fail closed; a merged record stays).
    local q="$1" num="$2" t="$3" h="$4" task="$5" d="$6" run="$7" evf qid rid url handle trc
    evf="$(dirname "$q")/events.jsonl"; qid=$(n1_read_frontmatter "$q" queue_id); rid=$(n1_read_frontmatter "$q" run_id)
    url=$(n1_queue_attested_pr "$q" "$t" "$h")
    if [ "$(n1_queue_pr_state "$url")" = MERGED ]; then
        n1_queue_row_status "$q" "$num" pr
        n1_queue_runs_outcome "$q" "$t" merged "$url"
        n1_queue_event "$evf" "$qid" "$rid" ticket_finished ticket="$t" outcome=merged pr="$url" session="orca:$task/$d"
        set -- merged
    else
        set -- stopped
    fi
    # Only a worker proven settled (exited, or a durable terminal state) keeps its terminal; anything else is closed
    # first, and a failed close changes nothing more (a merged record above is true either way).
    if [ "$1" = stopped ] || ! n1_orca_liveness "$run" | awk -F'\t' -v d="$d" '$1 == d && ($3 == "exited" || $4 == "done") { f = 1 } END { exit !f }'; then
        trc=0; handle=$(n1_orca_terminal_of "$run" "$d") || trc=$?   # errexit-safe capture of the tri-state rc
        if [ "$trc" = 2 ]; then
            echo "note: $t worker terminal already gone; nothing to close"
        elif [ "$trc" != 0 ] || ! n1_orca_terminal_close "$handle"; then
            echo "stop failed: $t (worker terminal not closed; row and identity kept)"
            return 1
        fi
    fi
    if [ "$1" = stopped ]; then
        n1_queue_row_status "$q" "$num" stopped "stopped by user"
        n1_queue_runs_outcome "$q" "$t" stopped
        n1_queue_event "$evf" "$qid" "$rid" ticket_finished ticket="$t" outcome=stopped session="orca:$task/$d"
    fi
    n1_orca_release "$d"
    n1_orca_sentinel_rm "$h" "$t" "$task"
    echo "$1: $t"
}

_n1_orca_common() { (cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P); }

_n1_orca_sentinel_ok() {
    # <checkout-top> <file> <check-queue 0|1> — the file exists, names this checkout's repo and (check-queue) its
    # queue run id is that queue's current run_id. No age limit: identity must outlive any wait (a child parked in
    # ask), and only the runner ends it (n1_orca_sentinel_rm on settle or final failure).
    local repo qdir rid
    [ -f "$2" ] || return 1
    repo=$(_n1_orca_sget "$2" N1_ORCA_REPO)
    [ -n "$repo" ] && [ "$(_n1_orca_common "$1")" = "$(_n1_orca_common "$repo")" ] || return 1
    [ "$3" = 1 ] || return 0
    qdir=$(_n1_orca_sget "$2" N1_QUEUE_DIR); rid=$(_n1_orca_sget "$2" N1_QUEUE_RUN_ID)
    [ -n "$rid" ] && [ -n "$qdir" ] && [ "$(n1_read_frontmatter "$qdir/queue.md" run_id 2>/dev/null)" = "$rid" ]
}

n1_orca_session_pin() {
    # Usage: n1_orca_session_pin <session-id> — after n1_orca_child_env at SessionStart: keep a copy of the sentinel
    # per session, so a child that deletes or edits its own sentinel (or the queue's run_id) stays a queue child.
    [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]] && [ -n "${N1_ORCA_SENTINEL:-}" ] || return 0
    local d="${N1_ORCA_SENTINEL%/sentinels/*}/sessions"
    # Only the first SessionStart pins: on compaction/resume the sentinel may have been edited, the pin must not follow.
    [ -e "$d/$N1_ORCA_TICKET.$1" ] || { mkdir -p "$d" && cp "$N1_ORCA_SENTINEL" "$d/$N1_ORCA_TICKET.$1" && chmod 600 "$d/$N1_ORCA_TICKET.$1"; }
}

n1_orca_child_env() {
    # Usage: n1_orca_child_env [cwd] [session-id] — load this checkout's queue-child identity into the calling process.
    # rc 0 and exports only when: ORCA_CLI_COMMAND is set (Orca terminal); the checkout folder name (Orca --name
    # <ticket>) is a ticket token with a sentinel; its repo shares this checkout's git common dir; its queue run id
    # is that queue's current run_id. Failing that, this session's pinned copy (n1_orca_session_pin) still counts, so
    # tampering with the sentinel or queue.md cannot drop the identity (fail closed). The file is parsed against the
    # key whitelist, never sourced. Also sets N1_ORCA_TICKET and N1_ORCA_SENTINEL.
    [ -n "${ORCA_CLI_COMMAND:-}" ] || return 1
    local top t f k s="${2:-}" h
    top=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || return 1
    t="${top##*/}"
    [[ "$t" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    # N1 home from the runner's fixed pointer, never n1_home (git config, $N1_HOME of the hook process).
    h=$(head -1 "$(n1_orca_home_ptr "$t")" 2>/dev/null) && [ -n "$h" ] || return 1
    f=$(n1_orca_sentinel_path "$h" "$t")
    if _n1_orca_sentinel_ok "$top" "$f" 1; then s=$f
    elif [[ "$s" =~ ^[A-Za-z0-9_-]+$ ]]; then s="$h/queue/sessions/$t.$s"; _n1_orca_sentinel_ok "$top" "$s" 0 || return 1
    else return 1; fi
    for k in $N1_ORCA_SENTINEL_KEYS; do export "$k=$(_n1_orca_sget "$s" "$k")"; done
    export N1_ORCA_TICKET="$t" N1_ORCA_SENTINEL="$f"
}

n1_orca_child_env_exports() {
    # Usage: n1_orca_child_env_exports — after n1_orca_child_env: "export K=<quoted>" lines for CLAUDE_ENV_FILE.
    local k
    for k in $N1_ORCA_SENTINEL_KEYS N1_ORCA_TICKET N1_ORCA_SENTINEL; do printf 'export %s=%q\n' "$k" "${!k:-}"; done
}

n1_orca_worker_done() {
    # Usage: n1_orca_worker_done — Stop hook, after n1_orca_child_env loaded: report this Orca queue child's stop
    # point to its coordinator exactly once per dispatch (<sentinel>.sent). escalated -> failed. succeeded only once
    # the run is over (N1-310): a PR is open (status pr) AND, when the unattended merge chain is authorized
    # (mergeOnFinish and fullAuto, as the runner's chain_authorized), overview.md carries the ## Finish block, else
    # step is done. A PR alone is not the end: the child still runs triage/CI/finish. Any other turn end sends
    # nothing (a premature worker_done would let the runner release and relaunch a live child). A lost send is not
    # fatal: the runner reconciles from overview.md and worker liveness. Requires lib/queue.sh. Always returns 0.
    [ -n "${N1_ORCA_TASK:-}" ] && [ -n "${N1_ORCA_DISPATCH:-}" ] && [ -n "${N1_ORCA_SENTINEL:-}" ] || return 0
    local sent="${N1_ORCA_SENTINEL%.env}.sent" ov st url oc=failed a home="${N1_ORCA_SENTINEL%/queue/sentinels/*}"
    [ "$(cat "$sent" 2>/dev/null)" = "$N1_ORCA_DISPATCH" ] && return 0
    ov="$home/memory/$N1_ORCA_TICKET/overview.md"
    # N1-271: a resumed worktree's overview keeps the previous attempt's terminal step until this worker rewrites it
    # (the runner wrote the identity file just before worker-start). ponytail: mtime order, not a run stamp.
    [ -z "${N1_ORCA_RESUME:-}" ] || [ "$ov" -nt "$N1_ORCA_SENTINEL" ] || return 0
    st=$(n1_queue_child_status "$ov" 0 1)
    case "$st" in
        escalated) ;;
        pr) if [ "$(N1_HOME="$home" N1_QUEUE_RUN_ID="${N1_QUEUE_RUN_ID:-orca}" n1_merge_authorized)" = true ]; then
                grep -q '^## Finish' "$ov" || return 0
            else
                [ "$(n1_read_frontmatter "$ov" step)" = done ] || return 0
            fi
            oc=succeeded ;;
        *) return 0 ;;
    esac
    url=$(n1_queue_child_pr_url "$ov")
    a=(orchestration send --type worker_done --outcome "$oc" --task-id "$N1_ORCA_TASK" --dispatch-id "$N1_ORCA_DISPATCH"
       --subject "$N1_ORCA_TICKET $st" --body "$st${url:+ $url}")
    [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && a+=(--from "$ORCA_TERMINAL_HANDLE")
    n1_orca "${a[@]}" >/dev/null 2>&1 && printf '%s\n' "$N1_ORCA_DISPATCH" > "$sent"
    return 0
}

n1_orca_beacon() {
    # Usage: n1_orca_beacon <start|stop|tick> [agent_type] — N1-315, hooks only (never skill text), after
    # n1_orca_child_env loaded: send this queue child's phase to its coordinator as a heartbeat. Phase = overview.md
    # current_step (else step), plus "/<persona>" on start; stop sends the step alone, so a persona start and finish
    # each send once. <sentinel>.beacon holds the last phase sent: an unchanged phase sends nothing unless the stamp is
    # 10+ minutes old (floor: a long single-phase persona must stay under queue.stallMinutes). tick (Stop,
    # PostToolUse) compares only the step part, so a persona-less hook firing inside a subagent never flaps the phase.
    # The send is backgrounded with output discarded; a lost send is repaired by the floor. Requires lib/frontmatter.sh.
    # Always returns 0.
    [ -n "${N1_ORCA_TASK:-}" ] && [ -n "${N1_ORCA_DISPATCH:-}" ] && [ -n "${N1_ORCA_SENTINEL:-}" ] || return 0
    local stamp="${N1_ORCA_SENTINEL%.env}.beacon" home="${N1_ORCA_SENTINEL%/queue/sentinels/*}" ov step p phase last a
    ov="$home/memory/${N1_ORCA_TICKET:-}/overview.md"
    step=$(n1_read_frontmatter "$ov" current_step 2>/dev/null)
    [ -n "$step" ] || step=$(n1_read_frontmatter "$ov" step 2>/dev/null)
    step="${step//[^A-Za-z0-9_.-]/}"
    [ -n "$step" ] || return 0
    p=$(n1_persona_name "${2:-}"); p="${p//[^A-Za-z0-9_.-]/}"
    phase="$step"; [ "$1" = start ] && [ -n "$p" ] && phase="$step/$p"
    phase="${phase:0:64}"
    last=$(cat "$stamp" 2>/dev/null)
    [ "$1" != tick ] || [ "${last%%/*}" != "$step" ] || phase="$last"
    [ "$phase" != "$last" ] || [ -n "$(find "$stamp" -mmin +10 2>/dev/null)" ] || return 0
    printf '%s\n' "$phase" > "$stamp" 2>/dev/null || return 0
    a=(orchestration send --type heartbeat --phase "$phase" --subject alive --task-id "$N1_ORCA_TASK" --dispatch-id "$N1_ORCA_DISPATCH")
    [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && a+=(--from "$ORCA_TERMINAL_HANDLE")
    ( n1_orca "${a[@]}" >/dev/null 2>&1 & ) 2>/dev/null
    return 0
}

n1_orca_ask() {
    # Usage: n1_orca_ask <question-file> [message-id] — Orca queue child (N1_ORCA_RUN set): put the ask-mode
    # QUESTION_FILE to the coordinator and wait up to 9 minutes (under the 10-minute command cap).
    # Prints answer:<text> | pending:<message-id> (unanswered so far: call again with that id) | failed.
    local out ans id a
    if [ -n "${2:-}" ]; then
        a=(orchestration ask --resume "$2")
    else
        [ -f "$1" ] || { echo failed; return 1; }
        # The option list keeps the recommended-option rule: one (Recommended) option with its rationale, or the
        # verbatim "No recommendation" sentence; optional alternatives notes (N1-216) follow in the question text.
        a=(orchestration ask --question "$(jq -r '"\(.ticket) \(.step): \(.question)" + (if (.recommended // "") != "" then " Recommended: \(.recommended). \(.rationale // "")" else " No recommendation. The options are equivalent given the available evidence; select based on team preference." end) + ((if (.alternatives | type) == "object" then ((.options | arrays) // []) as $o | [.alternatives | to_entries[] | select(.key as $k | any($o[]; . == $k))] | .[:10] else [] end) as $alt | if ($alt | length) > 0 then " Alternatives: " + ($alt | map("\(.key): \(.value)") | join("; ")) else "" end)' "$1" 2>/dev/null)"
           --options "$(jq -r '.recommended as $r | ((.options // []) | map(if . == $r then . + " (Recommended)" else . end) + ["Stop this ticket"]) | map(gsub(","; ";")) | join(",")' "$1" 2>/dev/null)")
    fi
    out=$(N1_ORCA_TIMEOUT=570 n1_orca "${a[@]}" --timeout-ms 540000)
    ans=$(jq -r '.result.answer // .result.reply.body // .result.body // empty' <<<"$out" 2>/dev/null)
    if [ -n "$ans" ]; then printf 'answer:%s\n' "$ans"; return 0; fi
    id=$(jq -r '.result.messageId // .result.message.id // .error.data.messageId // empty' <<<"$out" 2>/dev/null)
    id="${id:-${2:-}}"
    if _n1_orca_id "$id" && jq -e '.ok == true or ((.error.code // "") | test("timeout"; "i"))' <<<"$out" >/dev/null 2>&1; then
        printf 'pending:%s\n' "$id"; return 0
    fi
    echo failed
    return 1
}

n1_orca_reply() {
    # Usage: n1_orca_reply <queue-dir> <ticket> <answer> — n1-queue --answer for an Orca child: reply to the pending
    # ask message recorded in <queue-dir>/.ask-<ticket>. Markers are removed only after a successful reply.
    # N1-270: the reply is sent as the Run's coordinator (queue.md orca_coord_terminal, the runner's own terminal);
    # empty means the launching terminal coordinates (legacy), so the caller's own handle is used.
    # Requires lib/queue.sh (n1_queue_event).
    local dir="$1" t="$2" msg run coord
    msg=$(head -1 "$dir/.ask-$t" 2>/dev/null); run=$(n1_read_frontmatter "$dir/queue.md" orca_run_id)
    coord=$(n1_read_frontmatter "$dir/queue.md" orca_coord_terminal)
    _n1_orca_id "$msg" && _n1_orca_id "$run" || { echo "n1-queue: unreadable Orca question marker for $t" >&2; return 1; }
    [ -z "$coord" ] || _n1_orca_id "$coord" || { echo "n1-queue: unreadable Orca coordinator terminal for $t" >&2; return 1; }
    # A coordinator terminal that is gone (Orca restarted) must not block the answer: retry as the caller.
    N1_ORCA_TIMEOUT=30 n1_orca orchestration reply --id "$msg" --body "$3" --run "$run" ${coord:+--from "$coord"} >/dev/null \
        || { [ -n "$coord" ] && N1_ORCA_TIMEOUT=30 n1_orca orchestration reply --id "$msg" --body "$3" --run "$run" >/dev/null; } \
        || { echo "n1-queue: Orca reply failed for $t; retry --answer" >&2; return 1; }
    rm -f "$dir/.ask-$t" "$dir/.question-$t.json" "$dir/.esc-reason-$t"
    n1_queue_event "$dir/events.jsonl" "$(n1_read_frontmatter "$dir/queue.md" queue_id)" "$(n1_read_frontmatter "$dir/queue.md" run_id)" \
        answer_delivered ticket="$t" session="orca:$msg" reason="${3:0:120}"
    echo "n1-queue: answer delivered to $t (Orca message $msg)."
}

n1_orca_row_of_task() {
    # Usage: n1_orca_row_of_task <queue.md> <task> — "<ticket>\t<dispatch>" from the newest Runs row whose Session is
    # orca:<task>/<dispatch>; empty when no row names the task.
    awk -F'|' -v tk="orca:$2/" '/^## Runs/ { f = 1; next }
        f { s = $7; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            if (index(s, tk) == 1) { t = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); r = t "\t" substr(s, length(tk) + 1) } }
        END { if (r != "") print r }' "$1"
}

n1_orca_pending_questions() {
    # Usage: n1_orca_pending_questions <queue-dir> — N1-270: "<num>\t<ticket>\t<message-id>" per worker question waiting
    # in the queue's Orca Run inbox that no runner handled: no .ask-<ticket> marker and no answer_delivered event.
    # Reads as the Run's coordinator (queue.md orca_coord_terminal; empty: the caller's own terminal). check --all lists
    # every message without marking it read (--peek would miss one the dead runner read but never acked). Ids are
    # untrusted: the message must name the dispatch its task's Runs row holds (run_orca's rule), and that row must
    # be in-progress or awaiting-human in this queue run, or final (failed/pr/escalated) while its sentinel still names the
    # task (N1-309: the worker is not settled, so a settled worker's stale question never re-alerts). Requires
    # lib/queue.sh. Any failure prints nothing.
    local q="$1/queue.md" run coord out rows type task msg disp t d num n1h st
    run=$(n1_read_frontmatter "$q" orca_run_id); coord=$(n1_read_frontmatter "$q" orca_coord_terminal)
    _n1_orca_id "$run" && [ "$(n1_read_frontmatter "$q" orca_queue_run)" = "$(n1_read_frontmatter "$q" run_id)" ] || return 0
    [ -z "$coord" ] || _n1_orca_id "$coord" || return 0
    out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration check --run "$run" --all --types question ${coord:+--terminal "$coord"}) \
        || { [ -n "$coord" ] && out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration check --run "$run" --all --types question); } \
        || return 0   # a dead coordinator terminal (Orca restarted): retry as the caller, which resolves from its own env
    rows=$(n1_queue_pending_rows "$q" 'in-progress|awaiting-human|failed|pr|escalated')
    while IFS=$'\t' read -r type task msg disp; do
        [ "$type" = question ] && _n1_orca_id "$task" && _n1_orca_id "$msg" || continue
        IFS=$'\t' read -r t d <<< "$(n1_orca_row_of_task "$q" "$task")"
        [[ "$t" =~ ^[A-Za-z0-9_-]+$ ]] && [ "$disp" = "$d" ] && [ ! -e "$1/.ask-$t" ] || continue
        [ "$(n1_queue_session_id "$q" "$t")" = "orca:$task/$d" ] || continue   # only the ticket's latest attempt, not an older task
        IFS=$'\t' read -r num n1h st <<< "$(awk -F'\t' -v t="$t" '$2 == t { r = $1 "\t" $4 "\t" $6 } END { print r }' <<< "$rows")"
        [ -n "$num" ] || continue
        case "$st" in
            in-progress|awaiting-human) ;;
            *) [ "$(_n1_orca_sget "$(n1_orca_sentinel_path "$n1h" "$t")" N1_ORCA_TASK)" = "$task" ] || continue ;;
        esac
        [ -z "$(jq -R --arg s "orca:$msg" 'fromjson? | select(.event == "answer_delivered" and .session == $s)' "$1/events.jsonl" 2>/dev/null)" ] || continue
        printf '%s\t%s\t%s\n' "$num" "$t" "$msg"
    done < <(n1_orca_events "$out")
    return 0
}

# ---- Scheduled runs (N1-226) ----
# One Orca automation per project ("n1-queue <main-checkout folder> <6-hex of its path>", workspace = main checkout) runs
# scripts/n1-queue-precheck.sh (copied to <n1-home>/bin) and then "/n1:n1-queue --tag <tag> --unattended".
# Requires lib/config.sh (n1_orca, n1_main_checkout, n1_plugin_root, n1_home).
_n1_sched_safe() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
# <main-checkout> — automation name; the path hash keeps same-named folders of different projects apart.
_n1_sched_name() { printf 'n1-queue %s %06x' "${1##*/}" $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 16777216 )); }

_n1_sched_id() {
    # <name> — id of the automation with exactly this name. rc 1: none; rc 2: list unreadable.
    local out id
    out=$(N1_ORCA_TIMEOUT=30 n1_orca automations list) || return 2
    jq -e '(.result.automations // .result.items) | type == "array"' <<<"$out" >/dev/null 2>&1 || return 2
    id=$(jq -r --arg n "$1" '[(.result.automations // .result.items)[] | select(.name == $n) | .id // empty][0] // empty' <<<"$out" 2>/dev/null)
    _n1_orca_id "$id" || return 1
    printf '%s' "$id"
}

n1_queue_schedule() {
    # Usage: n1_queue_schedule create <tag> <trigger> <tracker-type> <tracker-mcp> <project-key> <todo-status>
    #      | n1_queue_schedule list | n1_queue_schedule remove
    # Prints one result line (list: "<id>\t<trigger>\t<enabled|disabled>" lines); rc 1 on failure. Re-create is
    # create + remove-old-by-id (Orca `edit` semantics unverified); the old automation goes only after the new
    # one exists, so a failed create keeps the previous schedule. Every value baked into the precheck command (it runs through a shell) is quote-free.
    local op="${1:-}" main name home id old r out pre tag trig ttype mcp key todo
    local trig_re='^[A-Za-z0-9*][A-Za-z0-9 */,:=;_-]*$' todo_re='^[A-Za-z0-9][A-Za-z0-9 ._-]*$'
    n1_orca_active || { echo "Orca workspace manager not reachable."; return 1; }
    main=$(n1_main_checkout "${CLAUDE_PROJECT_DIR:-.}") || { echo "Not inside a git checkout."; return 1; }
    name=$(_n1_sched_name "$main")
    case "$op" in
        list)
            out=$(N1_ORCA_TIMEOUT=30 n1_orca automations list) && jq -e '(.result.automations // .result.items) | type == "array"' <<<"$out" >/dev/null 2>&1 \
                || { echo "Could not list Orca automations."; return 1; }
            out=$(jq -r --arg n "$name" '(.result.automations // .result.items // [])[] | select(.name == $n)
                | "\(.id)\t\(.trigger // .schedule // "?")\t\(if .enabled == false then "disabled" else "enabled" end)"' <<<"$out" 2>/dev/null)
            printf '%s\n' "${out:-No scheduled run for $name.}" ;;
        remove)
            id=$(_n1_sched_id "$name"); r=$?
            case "$r" in 1) echo "No scheduled run for $name."; return 0 ;; 2) echo "Could not list Orca automations."; return 1 ;; esac
            N1_ORCA_TIMEOUT=30 n1_orca automations remove "$id" >/dev/null || { echo "Could not remove automation $id."; return 1; }
            echo "Removed scheduled run $id ($name)." ;;
        create)
            tag="${2:-}" trig="${3:-}" ttype="${4:-}" mcp="${5:-}" key="${6:-}" todo="${7:-}"
            home="${N1_HOME:-$(n1_home)}"
            _n1_sched_safe "$tag" && _n1_sched_safe "$key" || { echo "Invalid tag or project key."; return 1; }
            [[ "$trig" =~ $trig_re ]] || { echo "Invalid trigger: $trig"; return 1; }
            [[ "$todo" =~ $todo_re ]] || { echo "Invalid TODO status name: $todo"; return 1; }
            case "$home" in /*) ;; *) echo "N1 home is not an absolute path."; return 1 ;; esac
            case "$home" in *"'"*) echo "N1 home path contains a quote; cannot bake the precheck."; return 1 ;; esac
            # Only Jira has a REST check (credentials in the MCP secrets env); other trackers skip it in the precheck.
            case "$(printf '%s' "$ttype" | tr '[:upper:]' '[:lower:]')" in jira) _n1_sched_safe "$mcp" || mcp=none ;; *) mcp=none ;; esac
            mkdir -p "$home/bin" && cp "$(n1_plugin_root)/scripts/n1-queue-precheck.sh" "$home/bin/n1-queue-precheck.sh" \
                || { echo "Could not install the precheck under $home/bin."; return 1; }
            pre="bash '$home/bin/n1-queue-precheck.sh' '$home' '$tag' '$mcp' '$key' '$todo'"
            id=$(_n1_sched_id "$name"); r=$?
            [ "$r" -ne 2 ] || { echo "Could not list Orca automations; nothing created."; return 1; }
            old=""; [ "$r" -ne 0 ] || old="$id"
            out=$(N1_ORCA_TIMEOUT=30 n1_orca automations create --name "$name" --trigger "$trig" --provider claude \
                --workspace "path:$main" --workspace-mode existing --fresh-session --prompt "/n1:n1-queue --tag $tag --unattended" --precheck "$pre") || {
                echo "Orca automation create failed: $(jq -r '.error.message // empty' <<<"$out" 2>/dev/null)"; return 1; }
            id=$(jq -r '.result.automation.id // .result.id // empty' <<<"$out" 2>/dev/null)
            if [ -n "$old" ]; then
                N1_ORCA_TIMEOUT=30 n1_orca automations remove "$old" >/dev/null \
                    || { echo "Scheduled $name (${id:-unknown id}) but could not remove the previous automation $old; remove it with the workspace manager."; return 1; }
            fi
            echo "Scheduled $name ($trig): automation ${id:-unknown id}." ;;
        *) echo "Usage: n1_queue_schedule create|list|remove"; return 1 ;;
    esac
}
