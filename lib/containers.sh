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
# ponytail: a container started by someone else between snapshot and track is mis-tracked; add a compose-project label filter if it ever happens.
# Re-snapshot (fix cycle / resume) intentionally overwrites containers.before: a stale baseline would mis-track containers the user started in between (worse for AC4);
# containers already recorded in containers.tsv stay tracked, so only a start that crashed before its track call can leak (the n1-finish backstop cannot see those).

_n1_ct_dir() { # <ID> -> memory dir; fails on an unsafe id
    case "${1:-}" in ""|*[!A-Za-z0-9_-]*) return 1;; esac
    printf '%s/memory/%s' "${N1_HOME:-}" "$1"
}
_n1_ct_up() { docker ps -aq >/dev/null 2>&1; }

n1_containers_snapshot() {
    local d
    d=$(_n1_ct_dir "${1:-}") || { echo "containers: invalid id, not tracking"; return 0; }
    _n1_ct_up || { echo "containers: docker unavailable, not tracking"; return 0; }
    mkdir -p "$d" && docker ps -aq --no-trunc 2>/dev/null | LC_ALL=C sort > "$d/containers.before"
    echo "containers: snapshot taken"
    return 0
}

n1_containers_track() {
    local id="${1:-}" origin="${2:-local-testing}" d f cid name n=0
    d=$(_n1_ct_dir "$id") || { echo "containers: invalid id, not tracking"; return 0; }
    [ -f "$d/containers.before" ] || { echo "containers: no snapshot, nothing tracked"; return 0; }
    _n1_ct_up || { echo "containers: docker unavailable, not tracking"; return 0; }
    f="$d/containers.tsv"; touch "$f"
    while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        awk -F'\t' -v c="$cid" '$1==c{hit=1} END{exit !hit}' "$f" && continue
        name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null); name="${name#/}"
        docker update --restart=no "$cid" >/dev/null 2>&1 || echo "containers: could not set restart=no on ${name:-$cid}"
        printf '%s\t%s\t%s\n' "$cid" "${name:-?}" "$origin" >> "$f"
        n=$((n + 1))
    done < <(LC_ALL=C comm -13 "$d/containers.before" <(docker ps -aq --no-trunc 2>/dev/null | LC_ALL=C sort))
    echo "containers: tracked $n new"
    return 0
}

n1_containers_teardown() {
    local d f live cid name n=0 rc=0
    d=$(_n1_ct_dir "${1:-}") || { echo "containers: invalid id, teardown skipped"; return 0; }
    f="$d/containers.tsv"
    [ -s "$f" ] || { echo "containers: none tracked"; return 0; }
    _n1_ct_up || { echo "containers: docker unavailable, teardown skipped"; return 0; }
    live=$(docker ps -aq --no-trunc 2>/dev/null)
    while IFS=$'\t' read -r cid name _; do
        [ -n "$cid" ] || continue
        grep -qxF -- "$cid" <<<"$live" || continue   # already gone
        docker stop "$cid" >/dev/null 2>&1
        if docker rm -f -v "$cid" >/dev/null 2>&1; then n=$((n + 1)); else echo "containers: failed to remove $name ($cid)"; rc=1; fi
    done < "$f"
    echo "containers: removed $n tracked"
    return $rc
}
