#!/usr/bin/env bash
# tests/test_ci_rerun.sh -- N1-341: n1-ci reruns flaky/infra failures (cap 3 per head SHA) before developer dispatch.
# Helper units (lib/ci_rerun.sh) through a stubbed gh, plus wiring text checks.
# Run: bash tests/test_ci_rerun.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
source lib/ci_rerun.sh

PASS=0; FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS + 1)); else echo "FAIL: $1 -- expected '$2', got '$3'"; FAIL=$((FAIL + 1)); fi; }

# Stub gh: logs every call to $GH_CALLS; `pr view` prints $GH_SHA; `run view <id> --log-failed` prints
# $GH_DIR/log.<id> (missing file -> rc 1); `run rerun <id> --failed` exits $GH_RERUN_RC. Anything else fails.
mkdir "$T/bin"
cat > "$T/bin/gh" <<'EOG'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
    "pr view") [[ "$*" == *"--json headRefOid --jq .headRefOid"* ]] || exit 1; printf '%s\n' "$GH_SHA" ;;
    "run view") [ "$4" = "--log-failed" ] && cat "$GH_DIR/log.$3" 2>/dev/null ;;
    "run rerun") [ "$4" = "--failed" ] || exit 1; exit "${GH_RERUN_RC:-0}" ;;
    *) exit 1 ;;
esac
EOG
chmod +x "$T/bin/gh"
SHA1=$(printf 'a%.0s' $(seq 40)); SHA2=$(printf 'b%.0s' $(seq 40))
export PATH="$T/bin:$PATH" GH_CALLS="$T/calls" GH_DIR="$T" GH_RERUN_RC=0 GH_SHA="$SHA1"

OV="$T/overview.md"; TSV="$T/ci-fail.tsv"
ov() { printf -- '---\nstep: ci\nci_fix_cycle: 1\n---\n' > "$OV"; : > "$T/calls"; export GH_SHA="$SHA1" GH_RERUN_RC=0; }
L() { printf 'https://github.com/o/r/actions/runs/%s/job/9' "$1"; }
fails() { printf 'FAIL\t%s\t%s\n' "$@" > "$TSV"; }   # fails <name> <link> [<name> <link>]...
gate() { n1_ci_rerun_gate "$OV" 12 "$TSV" "${1:-}"; }
fm() { n1_read_frontmatter "$OV" "$1"; }
reruns() { grep -c '^run rerun ' "$T/calls"; }

# ---- AC1: an infra failure under the cap is rerun, not dispatched ----
ov; fails runner-timeout "$(L 111)"
eq "A1 infra-named check at count 0 -> rerun:1/3" "rerun:1/3" "$(gate)"
eq "A1b gh run rerun <id> --failed called once" "1" "$(grep -cxF 'run rerun 111 --failed' "$T/calls")"
eq "A1c ci_rerun_count=1" "1" "$(fm ci_rerun_count)"
eq "A1d ci_rerun_sha is the head SHA" "$SHA1" "$(fm ci_rerun_sha)"
eq "A1e no log fetched for a name match" "0" "$(grep -c '^run view' "$T/calls")"
ov; fails build "$(L 222)"; printf 'build\tTest\t2026-11-04T00:00:00Z Error: connect ETIMEDOUT 10.0.0.1:443\n' > "$T/log.222"
eq "A1f log shows a network timeout -> rerun:1/3" "rerun:1/3" "$(gate)"
ov; fails build "$(L 333)"; printf 'x\ty\tz Error: connect ETIMEDOUT\nx\ty\tz AssertionError: 1 != 2\n' > "$T/log.333"
eq "A1g timeout plus an assertion in the log -> dispatch" "dispatch" "$(gate)"
eq "A1h no rerun call on an assertion log" "0" "$(reruns)"
ov; fails build "$(L 334)"; printf 'x\ty\tz FAIL: tests/test_a.sh\nx\ty\tz connection reset by peer\n' > "$T/log.334"
eq "A1i FAIL: line in the log -> dispatch" "dispatch" "$(gate)"
ov; fails lint "$(L 444)"
eq "A1j non-infra name with no log available -> dispatch" "dispatch" "$(gate)"

# ---- AC2: fall-through to the existing path ----
ov; n1_write_frontmatter "$OV" ci_rerun_sha "$SHA1"; n1_write_frontmatter "$OV" ci_rerun_count 3
fails runner-timeout "$(L 111)"
eq "B1 count 3 at the same SHA -> dispatch" "dispatch" "$(gate)"
eq "B1b no rerun call at the cap" "0" "$(reruns)"
ov; n1_write_frontmatter "$OV" ci_rerun_sha "$SHA1"; n1_write_frontmatter "$OV" ci_rerun_count 2
fails runner-a "$(L 111)" runner-b "$(L 112)"
eq "B2 count 2 with 2 failed checks -> dispatch (all or nothing)" "dispatch" "$(gate)"
eq "B2b count unchanged" "2" "$(fm ci_rerun_count)"
ov; fails runner-timeout "$(L 111)"; gate >/dev/null
eq "B3 same check fails again after its rerun -> dispatch" "dispatch" "$(gate)"
eq "B3b only the first round reran" "1" "$(reruns)"
eq "B3c count stays 1" "1" "$(fm ci_rerun_count)"
ov
fails runner-1 "$(L 1)"; R1=$(gate); fails runner-2 "$(L 2)"; R2=$(gate); fails runner-3 "$(L 3)"; R3=$(gate)
eq "B4 three flaky failures -> 1/3, 2/3, 3/3" "rerun:1/3 rerun:2/3 rerun:3/3" "$R1 $R2 $R3"
fails runner-4 "$(L 4)"
eq "B4b 4th flaky failure at one SHA -> dispatch" "dispatch" "$(gate)"

# ---- AC3: a new push resets the counter ----
export GH_SHA="$SHA2"; fails runner-1 "$(L 5)"
eq "C1 new head SHA -> counter reset, rerun:1/3" "rerun:1/3" "$(gate)"
eq "C1b ci_rerun_sha updated" "$SHA2" "$(fm ci_rerun_sha)"
eq "C1c rerun memory holds only this SHA's check" "1" "$(fm ci_rerun_checks | wc -w | tr -d ' ')"

# ---- AC4: ci_fix_cycle is never touched by the gate ----
eq "D1 ci_fix_cycle unchanged after reruns and dispatches" "1" "$(fm ci_fix_cycle)"

# ---- fall-through edges ----
ov; fails runner-timeout "$(L 111)" lint "$(L 555)"; printf 'x\ty\tz AssertionError: no\n' > "$T/log.555"
eq "E1 mixed batch (infra + assertion) -> dispatch" "dispatch" "$(gate)"
eq "E1b mixed batch: no rerun, count 0" "0|0" "$(reruns)|$(fm ci_rerun_count)"
ov; export GH_RERUN_RC=1; fails runner-timeout "$(L 111)"
eq "E2 gh run rerun rejected -> dispatch" "dispatch" "$(gate)"
eq "E2b count restored, no check recorded" "0|" "$(fm ci_rerun_count)|$(fm ci_rerun_checks)"
ov; fails runner-a "$(L 700)" runner-b "https://github.com/o/r/actions/runs/700/job/2"
eq "E3 two checks sharing one run -> rerun:2/3" "rerun:2/3" "$(gate)"
eq "E3b one gh run rerun call for the shared run" "1" "$(reruns)"
ov; rm -f "$OV"; fails runner-timeout "$(L 111)"
eq "E4 missing overview.md (standalone) -> dispatch" "dispatch" "$(gate)"
eq "E4b no gh call without overview.md" "0" "$(wc -l < "$T/calls" | tr -d ' ')"
ov; fails runner-timeout "https://ci.example.com/build/1"
eq "E5 non-Actions link -> dispatch" "dispatch" "$(gate)"
ov; fails runner-deploy "$(L 111)"
eq "E6 escalate pattern match -> dispatch" "dispatch" "$(gate 'deploy|release')"
eq "E6b invalid escalate ERE -> dispatch" "dispatch" "$(gate '(')"
eq "E6c no rerun call on an escalate check" "0" "$(reruns)"
ov; fails runner-timeout "$(L 111)"
eq "E7 non-numeric PR -> dispatch" "dispatch" "$(n1_ci_rerun_gate "$OV" abc "$TSV")"
export GH_SHA=notasha
eq "E8 bad head SHA -> dispatch" "dispatch" "$(gate)"
ov; : > "$TSV"
eq "E9 empty fail file -> dispatch" "dispatch" "$(gate)"
ov; printf 'no frontmatter\n' > "$OV"; fails runner-timeout "$(L 111)"
eq "E10 state cannot be written (no frontmatter) -> dispatch" "dispatch" "$(gate)"
eq "E10b no rerun when the counter cannot be written" "0" "$(reruns)"

# ---- n1_ci_rerun_summary ----
ov; eq "F1 summary empty when nothing reran" "" "$(n1_ci_rerun_summary "$OV")"
n1_write_frontmatter "$OV" ci_rerun_count 1
eq "F2 summary for one rerun" "reran 1 flaky check (1/3)" "$(n1_ci_rerun_summary "$OV")"
n1_write_frontmatter "$OV" ci_rerun_count 2
eq "F3 summary plural" "reran 2 flaky checks (2/3)" "$(n1_ci_rerun_summary "$OV")"
eq "F4 summary empty without overview.md" "" "$(n1_ci_rerun_summary "$T/none.md")"

# ---- n1_ci_log_infra ----
printf 'x\ty\tz ##[error]The runner has received a shutdown signal.\n' > "$T/log.900"
n1_ci_log_infra 900; eq "H1 runner shutdown log -> infra" "0" "$?"
n1_ci_log_infra 901; eq "H2 unavailable log -> not infra" "1" "$?"
n1_ci_log_infra 'x;y'; eq "H3 non-numeric run id -> not infra" "1" "$?"

echo "PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
