#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
G="$ROOT/scripts/codex-push-gate.sh"
FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$3', want '$2')"; FAIL=1; fi; }
mkdir -p "$TMP/o/acme"; git init -q --bare "$TMP/o/acme/repo.git"
git init -q -b feat "$TMP/w"; cd "$TMP/w"
git config user.email t@t; git config user.name t
git remote add origin "$TMP/o/acme/repo.git"
echo a > a.txt; mkdir -p .github; echo y > .github/ci.yml; echo b > b.txt
git add -A; git commit -qm base; git push -q origin feat
git rev-parse HEAD > "$TMP/start"
printf 'a.txt\n.github/ci.yml\n' > "$TMP/allowed"
: > "$TMP/empty"
echo acme/repo > "$TMP/repo"; echo fork > "$TMP/fork"; echo other/repo > "$TMP/other"
eq "empty diff" "push:none" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
echo a2 >> a.txt; git commit -qam fix
eq "empty start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/empty" "$TMP/allowed" feat "$TMP/repo")"
eq "missing start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/nope" "$TMP/allowed" feat "$TMP/repo")"
eq "missing allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/nope" feat "$TMP/repo")"
eq "empty allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/empty" feat "$TMP/repo")"
eq "bad start sha fails closed" "push:blocked paths=gate-unavailable" "$(echo deadbeef > "$TMP/bad"; bash "$G" "$TMP/bad" "$TMP/allowed" feat "$TMP/repo")"
eq "branch mismatch fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/allowed" other "$TMP/repo")"
eq "start not ancestor" "push:blocked paths=gate-unavailable" "$(git rev-parse HEAD~1 > /dev/null; git rev-parse HEAD > "$TMP/s2"; git checkout -q -b tmp HEAD~1; echo n > n.txt; git add n.txt; git commit -qm n; git rev-parse HEAD > "$TMP/s3"; git checkout -q feat; bash "$G" "$TMP/s3" "$TMP/allowed" feat "$TMP/repo")"
eq "fork pr" "push:blocked paths=fork-pr" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/fork")"
eq "repo mismatch" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/other")"
eq "missing repo file" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/nope")"
# URL normalization (empty diff -> push:none proves the repo check passed)
HEADSHA=$(git rev-parse HEAD); echo "$HEADSHA" > "$TMP/head"
for u in git@github.com:acme/repo.git https://host/Acme/Repo/; do
  git remote set-url origin "$u"
  eq "url $u accepted" "push:none" "$(bash "$G" "$TMP/head" "$TMP/allowed" feat "$TMP/repo")"
done
git remote set-url origin https://host/acme/repo-evil
eq "evil url rejected" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/head" "$TMP/allowed" feat "$TMP/repo")"
git remote set-url origin git@github.com:acme/repo.git
git config remote.origin.pushurl https://host/other/repo.git
eq "pushurl mismatch rejected" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/head" "$TMP/allowed" feat "$TMP/repo")"
git config --unset remote.origin.pushurl
git remote set-url origin "$TMP/o/acme/repo.git"
git remote rename origin gone
eq "missing origin rejected" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/head" "$TMP/allowed" feat "$TMP/repo")"
git remote rename gone origin
echo b2 >> b.txt; git commit -qam outside
eq "path outside allowed" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
git reset -q --hard HEAD~1
echo z >> .github/ci.yml; git commit -qam ci
eq "denylisted path even if allowed" "push:blocked paths=.github/ci.yml" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
git reset -q --hard HEAD~1
git mv b.txt c.txt; git commit -qm rename; printf 'a.txt\nc.txt\n' > "$TMP/allowed-c"
eq "rename source not hidden" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-c" feat "$TMP/repo")"
git reset -q --hard HEAD~2
echo q > tmpf.txt; git add tmpf.txt; git commit -qm addf; git rm -q tmpf.txt; git commit -qm rmf
eq "add-then-remove forbidden file" "push:blocked paths=tmpf.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
git reset -q --hard HEAD~2
BASE=$(git rev-parse HEAD)
git checkout -q -b side; echo s > s.txt; git add s.txt; git commit -qm side
git checkout -q feat; echo a3 >> a.txt; git commit -qam mainline
git merge -q --no-ff --no-commit side; echo evil > b.txt; git add -A; git commit -qm merge
eq "merge commit out-of-scope path" "push:blocked paths=b.txt s.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
git reset -q --hard "$BASE"; git branch -q -D side
# N1-161: sibling new files. allowed-d adds a PR path in subdir d/ (the file need not exist locally).
printf 'a.txt\n.github/ci.yml\nd/x.txt\n' > "$TMP/allowed-d"
mkdir -p e; echo n > e/new.txt; git add e/new.txt; git commit -qm e
eq "new file in a dir with no allowed path" "push:blocked paths=e/new.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
echo n > .github/new.yml; git add .github/new.yml; git commit -qm ci2
eq "new CI file next to allowed CI file" "push:blocked paths=.github/new.yml" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
echo n > r.txt; git add r.txt; git commit -qm root
eq "new root file" "push:blocked paths=r.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/.hidden; git add d/.hidden; git commit -qm hidden
eq "new dot file in allowed dir" "push:blocked paths=d/.hidden" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d/sub; echo n > d/sub/f.txt; git add d/sub/f.txt; git commit -qm sub
eq "new file in a subdir of an allowed dir" "push:blocked paths=d/sub/f.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; printf '#!/bin/sh\n' > d/run.sh; chmod +x d/run.sh; ln -s ../a.txt d/ln; git add d/run.sh d/ln; git commit -qm modes
eq "new exec file and symlink in allowed dir" "push:blocked paths=d/ln d/run.sh" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/tmp.txt; git add d/tmp.txt; git commit -qm addt; git rm -q d/tmp.txt; git commit -qm rmt
eq "add-then-remove sibling stays blocked" "push:blocked paths=d/tmp.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/conftest.py; git add d/conftest.py; git commit -qm conftest
eq "new file with an extension not listed in that dir" "push:blocked paths=d/conftest.py" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/Makefile; git add d/Makefile; git commit -qm mk
eq "new extensionless file in allowed dir" "push:blocked paths=d/Makefile" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/credentials.txt; git add d/credentials.txt; git commit -qm cred
eq "deny regex beats sibling rule" "push:blocked paths=d/credentials.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
rm -f "$TMP/fix.patch"
eq "denylisted block with patch arg: kept, no patch" "push:blocked paths=d/credentials.txt kept=$(git rev-parse HEAD)" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo" "$TMP/fix.patch")"
eq "denylisted block: patch not written" "none" "$([ -e "$TMP/fix.patch" ] && echo exists || echo none)"
git reset -q --hard "$BASE"
mkdir -p d; ln -s ../a.txt d/sl.txt; git add d/sl.txt; git commit -qm sym1
rm d/sl.txt; echo n > d/sl.txt; git add d/sl.txt; git commit -qm sym2
eq "symlink in an intermediate commit stays blocked" "push:blocked paths=d/sl.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
git reset -q --hard "$BASE"
# N1-161: with PATCH_FILE, blocked/rejected fixes are saved and the branch reset to START
START=$(cat "$TMP/start")
echo b3 >> b.txt; git commit -qam outside2; TIP=$(git rev-parse HEAD)
eq "no patch arg: blocked line unchanged" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
eq "no patch arg: HEAD untouched" "$TIP" "$(git rev-parse HEAD)"
eq "blocked fix saved and reset" "push:blocked paths=b.txt reset=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo" "$TMP/fix.patch")"
eq "blocked reset lands on START" "$START" "$(git rev-parse HEAD)"
eq "saved patch applies on START" "ok" "$([ -s "$TMP/fix.patch" ] && git apply --check "$TMP/fix.patch" && echo ok)"
eq "saved patch is mode 600" "600" "$(stat -c %a "$TMP/fix.patch")"
git reset -q --hard "$TIP"; rm -f "$TMP/fix.patch"
echo dirty >> b.txt
eq "reset refused with overlapping local edit" "push:blocked paths=b.txt kept=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo" "$TMP/fix.patch")"
eq "kept leaves HEAD at tip" "$TIP" "$(git rev-parse HEAD)"
git checkout -q -- b.txt; rm -f "$TMP/fix.patch"
eq "fork pr with patch arg: no suffix" "push:blocked paths=fork-pr" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/fork" "$TMP/fix.patch")"
eq "fork pr with patch arg: no patch, HEAD untouched" "$TIP" "$([ -e "$TMP/fix.patch" ] || git rev-parse HEAD)"
git reset -q --hard "$BASE"
echo a4 >> a.txt; git commit -qam infix; TIP=$(git rev-parse HEAD)
printf '#!/bin/sh\nexit 1\n' > "$TMP/o/acme/repo.git/hooks/pre-receive"; chmod +x "$TMP/o/acme/repo.git/hooks/pre-receive"
eq "rejected push saved and reset" "push:rejected reset=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo" "$TMP/fix.patch")"
eq "rejected reset lands on START" "$START" "$(git rev-parse HEAD)"
rm -f "$TMP/fix.patch"
git reset -q --hard "$TIP"
git -C "$TMP/o/acme/repo.git" update-ref -d refs/heads/feat
eq "rejected push with remote ref missing: kept" "push:rejected kept=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo" "$TMP/fix.patch")"
eq "kept leaves HEAD at tip (remote ref missing)" "$TIP" "$(git rev-parse HEAD)"
git -C "$TMP/o/acme/repo.git" update-ref refs/heads/feat "$START"
rm "$TMP/o/acme/repo.git/hooks/pre-receive"; rm -f "$TMP/fix.patch"
git reset -q --hard "$BASE"
echo a2 >> a.txt; git commit -qam fix
printf '#!/bin/sh\nsleep 30\n' > "$TMP/w/.git/hooks/pre-push"; chmod +x "$TMP/w/.git/hooks/pre-push"
eq "hanging push times out" "push:rejected" "$(N1_CODEX_PUSH_TIMEOUT=2 bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
rm "$TMP/w/.git/hooks/pre-push"
eq "in-scope change pushes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed" feat "$TMP/repo")"
eq "remote ref updated" "$(git rev-parse HEAD)" "$(git -C "$TMP/o/acme/repo.git" rev-parse feat)"
mkdir -p d; echo n > d/new.txt; git add d/new.txt; git commit -qm sibling
eq "new regular file next to an allowed path pushes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
eq "sibling push updated remote" "$(git rev-parse HEAD)" "$(git -C "$TMP/o/acme/repo.git" rev-parse feat)"
echo n > "d/with space.txt"; git add "d/with space.txt"; git commit -qm spaced
eq "new file with a space in its name pushes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" feat "$TMP/repo")"
exit $FAIL
