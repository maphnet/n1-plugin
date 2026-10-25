#!/usr/bin/env bash
# N1-141: per-PR reviewed-head pin (n1_review_pin) and its wiring in n1-pr and reconcile § Check.
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/config.sh
FAIL=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2', got '$3')"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "repo view") [ -z "${REPO_FAIL:-}" ] || exit 1; echo "${REPO-o/r}" ;;
  "pr view") case "$*" in *headRefName*) echo "${BRANCH-tb}" ;; *) echo "${HEADSHA:-}" ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" N1_HOME="$T/home"
unset HEADSHA REPO REPO_FAIL BRANCH
git init -q "$T/repo"; cd "$T/repo"
tip() { echo "$1" > .git/refs/heads/tb; }   # local PR-branch tip (what N1 pushed)
A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333
tip $A
PIN="$T/home/review-pins/o_r_7"

eq "get: no pin prints nothing" "" "$(n1_review_pin get 7)"
eq "get: repo lookup failure -> unavailable" "pin:unavailable" "$(REPO_FAIL=1 n1_review_pin get 7)"
tip $B; eq "set: head != local tip -> unavailable" "pin:unavailable" "$(HEADSHA=$A n1_review_pin set 7)"
[ ! -e "$T/home/review-pins/o_r_7" ] && ok "set: foreign head writes no pin" || no "set: foreign head wrote a pin"
tip $A
eq "set: reports the pinned head" "pin:set 1111111" "$(HEADSHA=$A n1_review_pin set 7)"
eq "set: file holds the head" "$A" "$(cat "$PIN" 2>/dev/null)"
eq "get: roundtrip" "$A" "$(n1_review_pin get 7)"
eq "set: invalid head -> unavailable" "pin:unavailable" "$(HEADSHA=abc n1_review_pin set 7)"
eq "set: invalid head keeps the old pin" "$A" "$(cat "$PIN")"
eq "set: empty head -> unavailable" "pin:unavailable" "$(HEADSHA= n1_review_pin set 7)"
eq "advance: from != pin -> kept" "pin:kept" "$(n1_review_pin advance 7 "$C" "$B")"
eq "advance: kept leaves the pin" "$A" "$(cat "$PIN")"
eq "advance: NOW != local tip (n1-ci pushed nothing, foreign push) -> kept" "pin:kept" "$(n1_review_pin advance 7 "$A" "$B")"
eq "advance: kept leaves the pin" "$A" "$(n1_review_pin get 7)"
tip $B
eq "advance: from == pin and NOW == local tip -> advanced" "pin:advanced 2222222" "$(n1_review_pin advance 7 "$A" "$B")"
eq "advance: no local branch -> kept" "pin:kept" "$(BRANCH= n1_review_pin advance 7 "$B" "$C")"
eq "advance: pin moved to the new head" "$B" "$(cat "$PIN")"
eq "advance: invalid target -> unavailable" "pin:unavailable" "$(n1_review_pin advance 7 "$B" zz)"
eq "advance: invalid target keeps the pin" "$B" "$(cat "$PIN")"
eq "advance: no pin -> kept" "pin:kept" "$(n1_review_pin advance 8 "" "$B")"
[ ! -e "$T/home/review-pins/o_r_8" ] && ok "advance: no pin creates nothing" || no "advance: no pin created a file"
eq "set: non-digit PR rejected" "pin:unavailable" "$(HEADSHA=$A n1_review_pin set '7;x')"
eq "get: non-digit PR prints nothing" "" "$(n1_review_pin get '../7')"
eq "set: repo lookup failure -> unavailable" "pin:unavailable" "$(REPO_FAIL=1 HEADSHA=$A n1_review_pin set 9)"
eq "set: unsafe repo name rejected" "pin:unavailable" "$(REPO='o/r x' HEADSHA=$A n1_review_pin set 9)"
eq "set: rejected inputs write nothing" "o_r_7" "$(ls "$T/home/review-pins")"
echo junk > "$PIN"
eq "get: corrupt pin prints nothing" "" "$(n1_review_pin get 7)"
eq "advance: corrupt pin is never advanced" "pin:kept" "$(n1_review_pin advance 7 junk "$B")"
tip $C; eq "set: overwrites a corrupt pin" "pin:set 3333333" "$(HEADSHA=$C n1_review_pin set 7)"
eq "no temp files left behind" "0" "$(find "$T/home/review-pins" -name '*.*' | wc -l | tr -d ' ')"
n1_review_pin bogus 7 >/dev/null; eq "unknown op fails" "1" "$?"

# Wiring: n1-pr pins before the Codex runner; reconcile § Check advances (N1 fix-loop pushes only).
cd - >/dev/null; S3=skills/n1-pr/steps/03-codex-review.md
PS=$(grep -nF 'n1_review_pin set "${PR_URL##*/}"' "$S3" | head -1 | cut -d: -f1)
CR=$(grep -nF 'codex-pr-review.sh" "$PR_URL"' "$S3" | head -1 | cut -d: -f1)
if [ -n "$PS" ] && [ -n "$CR" ] && [ "$PS" -lt "$CR" ]; then ok "n1-pr pins the head before the Codex runner"; else no "n1-pr pins the head before the Codex runner"; fi

exit $FAIL
