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

n1_orca_task_create() {
    # Usage: n1_orca_task_create <run> <ticket> — prints the task id. The spec is the child's prompt; it names the
    # skill in words so it works whether or not a slash command still resolves after Orca's preamble.
    # --deps is always empty: same-plan blockers stay merge-gated held rows (N1-225 decision).
    local out id
    out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration task-create --run "$1" --task-title "$2" --deps '[]' \
        --spec "Invoke the n1-start skill for ticket $2 (equivalent to /n1:n1-start $2).") || return 1
    id=$(jq -r '.result.task.id // .result.id // empty' <<<"$out" 2>/dev/null)
    _n1_orca_id "$id" || return 1
    printf '%s' "$id"
}

n1_orca_worker_start() {
    # Usage: n1_orca_worker_start <run> <task> <ticket> <repo> <model> — prints the dispatch id (exit 0), else
    # "orca-launch:<failedStage>" (exit 1). A launch rejected for its model is retried once without --model (row
    # models are aliases; Orca takes opaque provider ids). Any other failure is final: Orca forbids blind relaunch.
    local model="${5:-}" out id why rc
    local a=(orchestration worker-start --run "$1" --task "$2" --worktree new-top-level --name "$3" --repo "path:$4" --agent claude)
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
    # (an empty batch is a checkpoint, not a failure).
    N1_ORCA_TIMEOUT=$(( $2 + 30 )) n1_orca orchestration check --run "$1" --wait \
        --types worker_done,escalation,question --timeout-ms $(( $2 * 1000 ))
}

n1_orca_events() {
    # Usage: n1_orca_events <check-json> — "<type>\t<task-id>\t<message-id>" per message.
    jq -r '(.result.messages // .result.batch // .result.items // [])[]?
        | [(.type // .messageType // ""), (.taskId // .task_id // .task.id // ""), (.id // .messageId // "")] | @tsv' <<<"$1" 2>/dev/null
    return 0
}

n1_orca_ack() {
    # Usage: n1_orca_ack <run> <check-json> — acknowledge the batch so check stops replaying it. Best-effort.
    local d; d=$(jq -r '.result.deliveryId // .result.delivery_id // .result.delivery.id // empty' <<<"$2" 2>/dev/null)
    _n1_orca_id "$d" && n1_orca orchestration check --run "$1" --ack "$d" >/dev/null
    return 0
}

n1_orca_liveness() {
    # Usage: n1_orca_liveness <run> — "<dispatch>\t<task>\t<live|unverifiable|exited>" per worker; non-zero when
    # the list is unreadable. Orca reports liveness as {"verdict":..,"reason":..} (a bare string is still accepted);
    # a missing or non-string verdict reads unverifiable: only positive proof of exit settles a worker.
    local out; out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration worker-list --run "$1") || return 1
    # Only an ok receipt with an array-shaped worker collection is a readable list; anything else is non-zero.
    jq -r '(.result.workers // .result.dispatches // .result.items) as $w
        | if .ok == true and ($w | type) == "array" then $w[]
            | [(.dispatchId // .dispatch.id // .id // ""), (.taskId // .task.id // ""),
               (.projection.liveness | if type == "object" then .verdict else . end
                    | if type == "string" then . else "unverifiable" end)] | @tsv
          else error("unreadable worker list") end' <<<"$out" 2>/dev/null
}

n1_orca_release() {
    # Usage: n1_orca_release <dispatch> — worker-release (idempotent). Best-effort.
    _n1_orca_id "${1:-}" && n1_orca orchestration worker-release --dispatch "$1" >/dev/null 2>&1
    return 0
}

n1_orca_worktree_taken() {
    # Usage: n1_orca_worktree_taken <ticket> — true when an Orca worktree folder is already named <ticket>. The
    # identity loader keys on that folder name; if Orca deduplicated a clashing --name (e.g. T-1-2), the child would
    # start without its sentinel (merge guard off). An unreadable list reads "taken" (fail closed: the row fails, no worker starts blind).
    local out; out=$(N1_ORCA_TIMEOUT=30 n1_orca worktree list) || return 0
    jq -e --arg n "$1" 'if (.result.worktrees | type) == "array" then any(.result.worktrees[]; (.path | split("/") | last) == $n) else true end' <<<"$out" >/dev/null 2>&1
    [ $? -ne 1 ]
}

# ---- Identity sentinel (N1-225) ----
# worker-start has no env flag, so an Orca child would run as an interactive session (merge guard off, a question
# TUI nobody answers). The runner writes $N1_HOME/queue/sentinels/<ticket>.env before worker-start; SessionStart
# persists it for Bash commands via CLAUDE_ENV_FILE and every hook loads it into its own process.
N1_ORCA_SENTINEL_KEYS="N1_HEADLESS N1_AUTONOMY_PRESET N1_UNATTENDED N1_QUEUE_RUN_ID N1_QUEUE_TAG N1_QUEUE_DIR N1_PARENT_SESSION_ID N1_ORCA_REPO N1_ORCA_RUN N1_ORCA_TASK N1_ORCA_DISPATCH"

n1_orca_sentinel_path() { printf '%s/queue/sentinels/%s.env' "$1" "$2"; }   # <n1-home> <ticket>
# <ticket> — fixed, git-independent pointer to the ticket's N1 home: the loader never resolves the home through git
# config, which a child can change (git remote set-url). ponytail: keyed by ticket only; ticket ids carry a project prefix.
n1_orca_home_ptr() { printf '%s/.n1/orca-home/%s' "$HOME" "$1"; }

n1_orca_sentinel_write() {
    # Usage: n1_orca_sentinel_write <n1-home> <ticket> <repo> <queue-run-id> <orca-run> <task>
    # Runner side, before worker-start: KEY=value lines (same env as a bg child's --settings), mode 600, atomic.
    local f t
    f=$(n1_orca_sentinel_path "$1" "$2")
    mkdir -p "${f%/*}" && t=$(mktemp "$f.XXXXXX") || return 1
    chmod 600 "$t"
    {
        printf 'N1_HEADLESS=1\nN1_AUTONOMY_PRESET=autonomous\nN1_UNATTENDED=ask\n'
        printf 'N1_QUEUE_RUN_ID=%s\nN1_QUEUE_TAG=%s\nN1_QUEUE_DIR=%s\nN1_PARENT_SESSION_ID=%s\n' \
            "$4" "${N1_QUEUE_TAG:-}" "${N1_QUEUE_DIR:-}" "$(n1_session_id 2>/dev/null)"
        printf 'N1_ORCA_REPO=%s\nN1_ORCA_RUN=%s\nN1_ORCA_TASK=%s\n' "$3" "$5" "$6"
    } > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
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
    rm -f "$f" "${f%.env}.sent" "${f%/*/*}/sessions/$2".*
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
    # point to its coordinator exactly once per dispatch (<sentinel>.sent). Only a terminal overview step counts:
    # pr -> succeeded, escalated -> failed. Any other turn end sends nothing (a premature worker_done would let the
    # runner relaunch a live child). A lost send is not fatal: the runner reconciles from overview.md and worker
    # liveness. Requires lib/queue.sh. Always returns 0.
    [ -n "${N1_ORCA_TASK:-}" ] && [ -n "${N1_ORCA_DISPATCH:-}" ] && [ -n "${N1_ORCA_SENTINEL:-}" ] || return 0
    local sent="${N1_ORCA_SENTINEL%.env}.sent" ov st url oc=failed a
    [ "$(cat "$sent" 2>/dev/null)" = "$N1_ORCA_DISPATCH" ] && return 0
    ov="${N1_ORCA_SENTINEL%/queue/sentinels/*}/memory/$N1_ORCA_TICKET/overview.md"
    st=$(n1_queue_child_status "$ov" 0 1)
    case "$st" in pr) oc=succeeded ;; escalated) ;; *) return 0 ;; esac
    url=$(n1_queue_child_pr_url "$ov")
    a=(orchestration send --type worker_done --outcome "$oc" --task-id "$N1_ORCA_TASK" --dispatch-id "$N1_ORCA_DISPATCH"
       --subject "$N1_ORCA_TICKET $st" --body "$st${url:+ $url}")
    [ -n "${ORCA_TERMINAL_HANDLE:-}" ] && a+=(--from "$ORCA_TERMINAL_HANDLE")
    n1_orca "${a[@]}" >/dev/null 2>&1 && printf '%s\n' "$N1_ORCA_DISPATCH" > "$sent"
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
        # verbatim "No recommendation" sentence.
        a=(orchestration ask --question "$(jq -r '"\(.ticket) \(.step): \(.question)" + (if (.recommended // "") != "" then " Recommended: \(.recommended). \(.rationale // "")" else " No recommendation. The options are equivalent given the available evidence; select based on team preference." end)' "$1" 2>/dev/null)"
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
    # Requires lib/queue.sh (n1_queue_event).
    local dir="$1" t="$2" msg run
    msg=$(head -1 "$dir/.ask-$t" 2>/dev/null); run=$(n1_read_frontmatter "$dir/queue.md" orca_run_id)
    _n1_orca_id "$msg" && _n1_orca_id "$run" || { echo "n1-queue: unreadable Orca question marker for $t" >&2; return 1; }
    N1_ORCA_TIMEOUT=30 n1_orca orchestration reply --id "$msg" --body "$3" --run "$run" >/dev/null \
        || { echo "n1-queue: Orca reply failed for $t; retry --answer" >&2; return 1; }
    rm -f "$dir/.ask-$t" "$dir/.question-$t.json" "$dir/.esc-reason-$t"
    n1_queue_event "$dir/events.jsonl" "$(n1_read_frontmatter "$dir/queue.md" queue_id)" "$(n1_read_frontmatter "$dir/queue.md" run_id)" \
        answer_delivered ticket="$t" session="orca:$msg" reason="${3:0:120}"
    echo "n1-queue: answer delivered to $t (Orca message $msg)."
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
