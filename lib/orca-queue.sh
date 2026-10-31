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
    # the list is unreadable. A missing liveness reads unverifiable: only positive proof of exit settles a worker.
    local out; out=$(N1_ORCA_TIMEOUT=30 n1_orca orchestration worker-list --run "$1") || return 1
    jq -r '(.result.workers // .result.dispatches // .result.items // [])[]?
        | [(.dispatchId // .dispatch.id // .id // ""), (.taskId // .task.id // ""), (.projection.liveness // "unverifiable")] | @tsv' <<<"$out" 2>/dev/null
}

n1_orca_release() {
    # Usage: n1_orca_release <dispatch> — worker-release (idempotent). Best-effort.
    _n1_orca_id "${1:-}" && n1_orca orchestration worker-release --dispatch "$1" >/dev/null 2>&1
    return 0
}

n1_orca_worktree_taken() {
    # Usage: n1_orca_worktree_taken <ticket> — true when an Orca worktree folder is already named <ticket>. The
    # identity loader keys on that folder name; if Orca deduplicated a clashing --name (e.g. T-1-2), the child would
    # start without its sentinel (merge guard off). An unreadable list reads "not taken" (same shape as n1_orca_owns).
    N1_ORCA_TIMEOUT=30 n1_orca worktree list | jq -e --arg n "$1" 'any(.result.worktrees[]?; (.path | split("/") | last) == $n)' >/dev/null 2>&1
}
