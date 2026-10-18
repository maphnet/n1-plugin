#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
G="$ROOT/scripts/codex-push-gate.sh"
FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$3', want '$2')"; FAIL=1; fi; }
git init -q --bare "$TMP/origin.git"
git init -q -b feat "$TMP/w"; cd "$TMP/w"
git config user.email t@t; git config user.name t
git remote add origin "$TMP/origin.git"
echo a > a.txt; mkdir -p .github; echo y > .github/ci.yml; echo b > b.txt
git add -A; git commit -qm base; git push -q origin feat
git rev-parse HEAD > "$TMP/start"
printf 'a.txt\n.github/ci.yml\n' > "$TMP/allowed"
: > "$TMP/empty"
eq "empty diff" "push:none" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat)"
echo a2 >> a.txt; git commit -qam fix
eq "empty start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/empty" "$TMP/allowed" feat)"
eq "missing start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/nope" "$TMP/allowed" feat)"
eq "missing allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/nope" feat)"
eq "empty allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/empty" feat)"
eq "bad start sha fails closed" "push:blocked paths=gate-unavailable" "$(echo deadbeef > "$TMP/bad"; bash "$G" "$TMP/bad" "$TMP/allowed" feat)"
eq "branch mismatch fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/allowed" other)"
echo b2 >> b.txt; git commit -qam outside
eq "path outside allowed" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat)"
git reset -q --hard HEAD~1
echo z >> .github/ci.yml; git commit -qam ci
eq "denylisted path even if allowed" "push:blocked paths=.github/ci.yml" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat)"
git reset -q --hard HEAD~1
eq "in-scope change pushes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat)"
eq "remote ref updated" "$(git rev-parse HEAD)" "$(git -C "$TMP/origin.git" rev-parse feat)"
exit $FAIL
