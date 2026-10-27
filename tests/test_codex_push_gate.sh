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
