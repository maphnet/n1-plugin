#!/usr/bin/env bash
# N1-54: track Docker containers N1 starts for development / local testing, force --restart=no, stop them when done.
#
# Ledger:   $N1_HOME/memory/<ID>/containers.tsv   (container-id <TAB> name <TAB> origin), kept after teardown as the run record
# Snapshot: $N1_HOME/memory/<ID>/containers.before (sorted ids present before the start command)
#
#   n1_containers_snapshot <ID>            run BEFORE the start command
#   n1_containers_track    <ID> [origin]   run right AFTER it: records new containers, sets restart=no
#   n1_containers_teardown <ID>            stop + remove exactly the recorded containers (never prune, never project-wide down)
#
# Every function returns 0 when Docker is missing/unreachable (the feature must never fail a run that does not use Docker).
# Ownership: track records only containers new since the snapshot AND owned by this run: label n1.ticket=<ID>, or compose working_dir whose git toplevel is this worktree
# (no git root -> label only). Containers of other sessions/stacks are never recorded, changed or removed. Plain `docker run` must pass --label n1.ticket=<ID>.
# track may be called again after later starts (idempotent); each call advances the baseline, so it never diffs against a stale snapshot.
# Snapshot/track fail closed: if docker ps fails, no baseline is kept and nothing is tracked.

_n1_ct_dir() { # <ID> -> memory dir; fails on an unsafe id
    case "${1:-}" in ""|*[!A-Za-z0-9_-]*) return 1;; esac
    printf '%s/memory/%s' "${N1_HOME:-}" "$1"
}
_n1_ct_up() { docker ps -aq >/dev/null 2>&1; }

_n1_ct_list() { # sorted full ids; non-zero when docker ps fails
    local out; out=$(docker ps -aq --no-trunc 2>/dev/null) || return 1
    printf '%s\n' "$out" | LC_ALL=C sort
}
_n1_ct_owned() { # <cid> <ticket> <root>
    local l wd
    l=$(docker inspect -f '{{index .Config.Labels "n1.ticket"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$1" 2>/dev/null) || return 2   # 2 = inspect failed, retry later
    wd="${l#*|}"
    [ -n "${l%%|*}" ] && { [ "${l%%|*}" = "$2" ]; return; }   # explicit label: exact match only, another ticket's container is never ours
    # compose working_dir must belong to THIS worktree (its own git toplevel), not merely sit under it (other worktrees nest in the main checkout)
    [ -n "$3" ] && [ -n "$wd" ] && [ "$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wd" rev-parse --show-toplevel 2>/dev/null)" = "$3" ] && return 0
    return 1
}

n1_containers_snapshot() {
    local d list
    d=$(_n1_ct_dir "${1:-}") || { echo "containers: invalid id, not tracking"; return 0; }
    rm -f "$d/containers.before" 2>/dev/null
    _n1_ct_up || { echo "containers: docker unavailable, not tracking"; return 0; }
    list=$(_n1_ct_list) && mkdir -p "$d" && printf '%s\n' "$list" > "$d/containers.before" \
        || { rm -f "$d/containers.before"; echo "containers: snapshot failed, not tracking"; return 0; }
    echo "containers: snapshot taken"
    return 0
}

n1_containers_track() {
    local id="${1:-}" origin="${2:-local-testing}" d f p cid name root now keep n=0 skipped=0 rc
    d=$(_n1_ct_dir "$id") || { echo "containers: invalid id, not tracking"; return 0; }
    [ -f "$d/containers.before" ] || { echo "containers: no snapshot, nothing tracked"; return 0; }
    now=$(_n1_ct_list) || { echo "containers: docker unavailable, not tracking"; return 0; }
    root=$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null) || root=""
    keep="$now"
    f="$d/containers.tsv"; touch "$f"
    p="$d/containers.pending"   # ids whose restart=no failed; retried on every track call
    if [ -s "$p" ]; then
        while IFS= read -r cid; do
            [ -n "$cid" ] || continue
            grep -qxF -- "$cid" <<<"$now" || continue   # gone, drop
            docker update --restart=no "$cid" >/dev/null 2>&1 && continue
            printf '%s\n' "$cid" >> "$p.new"
        done < "$p"
        if [ -f "$p.new" ]; then mv -f "$p.new" "$p"; else rm -f "$p"; fi
    fi
    while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        awk -F'\t' -v c="$cid" '$1==c{hit=1} END{exit !hit}' "$f" && continue
        _n1_ct_owned "$cid" "$id" "$root"; rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 2 ]; then keep=$(grep -vxF -- "$cid" <<<"$keep"); else skipped=$((skipped + 1)); fi
            continue
        fi
        name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null); name="${name#/}"
        docker update --restart=no "$cid" >/dev/null 2>&1 || { echo "containers: could not set restart=no on ${name:-$cid}, will retry"; printf '%s\n' "$cid" >> "$p"; }
        printf '%s\t%s\t%s\n' "$cid" "${name:-?}" "$origin" >> "$f"
        n=$((n + 1))
    done < <(LC_ALL=C comm -13 "$d/containers.before" <(printf '%s\n' "$now"))
    printf '%s\n' "$keep" > "$d/containers.before"
    [ "$skipped" -eq 0 ] || echo "containers: ignored $skipped new container(s) not owned by this run (missing --label n1.ticket=$id?)"
    echo "containers: tracked $n new"
    return 0
}

n1_containers_teardown() {
    local d f live cid name n=0 rc=0
    d=$(_n1_ct_dir "${1:-}") || { echo "containers: invalid id, teardown skipped"; return 0; }
    f="$d/containers.tsv"
    [ -s "$f" ] || { echo "containers: none tracked"; return 0; }
    _n1_ct_up || { echo "containers: docker unavailable, teardown skipped"; return 0; }
    live=$(docker ps -aq --no-trunc 2>/dev/null) || { echo "containers: could not list containers, teardown incomplete"; return 1; }
    while IFS=$'\t' read -r cid name _; do
        [ -n "$cid" ] || continue
        grep -qxF -- "$cid" <<<"$live" || continue   # already gone
        docker stop "$cid" >/dev/null 2>&1
        if docker rm -f -v "$cid" >/dev/null 2>&1; then n=$((n + 1)); else echo "containers: failed to remove $name ($cid)"; rc=1; fi
    done < "$f"
    echo "containers: removed $n tracked"
    return $rc
}
