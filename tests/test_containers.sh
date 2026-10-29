#!/usr/bin/env bash
# tests/test_containers.sh
# N1-54: lib/containers.sh snapshot/track/teardown against a fake `docker` on PATH (no real Docker).
# Run: bash tests/test_containers.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1 -- $2"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
has() { case "$3" in *"$2"*) ok "$1";; *) no "$1" "'$2' not in '$3'";; esac; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FAKE="$T/fake"
mkdir -p "$FAKE/bin" "$T/home/memory/T-1" "$T/home/memory/T-3" "$T/empty"
: > "$FAKE/containers"; : > "$FAKE/calls"; : > "$FAKE/updated"; : > "$FAKE/stopped"; : > "$FAKE/removed"

# Fake docker: state in $FAKE. Supports ps -aq [--no-trunc], inspect -f ... <id>, update --restart=no <id>, stop <id>, rm -f -v <id>.
cat > "$FAKE/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
last="${@: -1}"
case "$1" in
  ps) cat "$FAKE/containers" ;;
  inspect) echo "/name-$last" ;;
  update) [ "${FAKE_UPDATE_FAIL:-}" = "$last" ] && exit 1; echo "$last" >> "$FAKE/updated" ;;
  stop) echo "$2" >> "$FAKE/stopped" ;;
  rm) [ "${FAKE_RM_FAIL:-}" = "$last" ] && exit 1
      grep -vxF -- "$last" "$FAKE/containers" > "$FAKE/c.tmp"; mv "$FAKE/c.tmp" "$FAKE/containers"
      echo "$last" >> "$FAKE/removed" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$FAKE/bin/docker"
export PATH="$FAKE/bin:$PATH"
export N1_HOME="$T/home"
source "$REPO_ROOT/lib/containers.sh"

add() { printf '%s\n' "$@" >> "$FAKE/containers"; }
D="$N1_HOME/memory/T-1"
lines() { paste -sd' ' "$1"; }

# ---- snapshot ----
add aaa111 bbb222
n1_containers_snapshot T-1 >/dev/null
eq "S1: snapshot lists pre-existing containers" "aaa111 bbb222" "$(lines "$D/containers.before")"

# ---- track: only containers new since the snapshot (AC1, AC4) ----
add ccc333 ddd444
OUT=$(n1_containers_track T-1 local-testing)
eq "T1: ledger has only the new containers" "ccc333 ddd444" "$(cut -f1 "$D/containers.tsv" | paste -sd' ')"
eq "T2: ledger records names" "name-ccc333 name-ddd444" "$(cut -f2 "$D/containers.tsv" | paste -sd' ')"
eq "T3: ledger records origin" "local-testing" "$(cut -f3 "$D/containers.tsv" | sort -u)"
eq "T4: restart policy set to no on new containers only (AC3)" "ccc333 ddd444" "$(lines "$FAKE/updated")"
has "T5: docker update uses --restart=no" "update --restart=no ccc333" "$(cat "$FAKE/calls")"
has "T6: track prints a summary" "tracked 2" "$OUT"

# ---- track is idempotent ----
n1_containers_track T-1 >/dev/null
eq "T7: re-track adds no ledger rows" "2" "$(wc -l < "$D/containers.tsv" | tr -d ' ')"
eq "T8: re-track does not re-update" "2" "$(wc -l < "$FAKE/updated" | tr -d ' ')"

# ---- track without a snapshot records nothing (fail safe toward AC4) ----
OUT=$(n1_containers_track T-2)
eq "T9: no snapshot -> no ledger" "no" "$([ -e "$N1_HOME/memory/T-2/containers.tsv" ] && echo yes || echo no)"
has "T10: no snapshot -> warns" "no snapshot" "$OUT"

# ---- docker update failure: still recorded, surfaced ----
add eee555
OUT=$(FAKE_UPDATE_FAIL=eee555 n1_containers_track T-1)
has "T11: update failure is surfaced" "could not set restart=no" "$OUT"
eq "T12: update-failed container is still recorded" "3" "$(wc -l < "$D/containers.tsv" | tr -d ' ')"

# ---- teardown: only tracked containers; unrelated survive (AC2, AC4) ----
printf '%s\n' aaa111 bbb222 ccc333 eee555 > "$FAKE/containers"   # ddd444 vanished before teardown
OUT=$(n1_containers_teardown T-1); RC=$?
eq "D1: teardown rc 0" "0" "$RC"
eq "D2: stopped only live tracked containers" "ccc333 eee555" "$(lines "$FAKE/stopped")"
eq "D3: removed only live tracked containers" "ccc333 eee555" "$(lines "$FAKE/removed")"
eq "D4: unrelated containers untouched" "aaa111 bbb222" "$(lines "$FAKE/containers")"
eq "D5: no prune / compose-down ever issued" "0" "$(grep -cE 'prune|compose' "$FAKE/calls" || true)"
has "D6: rm uses -f -v" "rm -f -v ccc333" "$(cat "$FAKE/calls")"
has "D7: teardown prints a summary" "removed 2" "$OUT"
n1_containers_teardown T-1 >/dev/null
eq "D8: second teardown is a no-op" "2" "$(wc -l < "$FAKE/stopped" | tr -d ' ')"

# ---- rm failure on an existing container: reported, rc 1 ----
n1_containers_snapshot T-3 >/dev/null
add fff666
n1_containers_track T-3 >/dev/null
OUT=$(FAKE_RM_FAIL=fff666 n1_containers_teardown T-3); RC=$?
eq "F1: rm failure returns 1" "1" "$RC"
has "F2: rm failure is reported" "failed to remove" "$OUT"

# ---- nothing tracked ----
OUT=$(n1_containers_teardown T-2); RC=$?
eq "N1: no ledger -> rc 0" "0" "$RC"
has "N2: no ledger -> says none tracked" "none tracked" "$OUT"

# ---- docker missing: every helper is a no-op returning 0 ----
OUT=$( (PATH="$T/empty"; n1_containers_snapshot T-4; echo "rc=$?") 2>&1)
has "X1: docker missing -> note" "docker unavailable" "$OUT"
has "X2: docker missing -> rc 0" "rc=0" "$OUT"
OUT=$( (PATH="$T/empty"; n1_containers_teardown T-1; echo "rc=$?") 2>&1)
has "X3: teardown with docker missing -> rc 0" "rc=0" "$OUT"

# ---- invalid ticket id never builds a path ----
OUT=$(n1_containers_snapshot '../x'); RC=$?
has "I1: invalid id -> note" "invalid id" "$OUT"
eq "I2: invalid id -> rc 0" "0" "$RC"
eq "I3: invalid id wrote nothing" "no" "$([ -e "$N1_HOME/x" ] && echo yes || echo no)"

[ "$FAIL" -eq 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit $FAIL
