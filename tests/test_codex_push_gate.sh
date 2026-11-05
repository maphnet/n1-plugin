#!/usr/bin/env bash
# N1-405: pre-push scope gate for Codex fix commits (allowlist, N1-161 siblings, DENY, reset+patch). It never pushes.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
G="$ROOT/scripts/codex-push-gate.sh"
FAIL=0
eq() { if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$3', want '$2')"; FAIL=1; fi; }
git init -q --bare "$TMP/remote.git"
git init -q -b feat "$TMP/w"; cd "$TMP/w"
git config user.email t@t; git config user.name t
git remote add origin "$TMP/remote.git"
echo a > a.txt; mkdir -p .github; echo y > .github/ci.yml; echo b > b.txt
git add -A; git commit -qm base; git push -q origin feat
git rev-parse HEAD > "$TMP/start"
REMOTE0=$(git -C "$TMP/remote.git" rev-parse feat)
printf 'a.txt\n.github/ci.yml\n' > "$TMP/allowed"
: > "$TMP/empty"
eq "empty diff" "push:none" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
echo a2 >> a.txt; git commit -qam fix
eq "empty start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/empty" "$TMP/allowed")"
eq "missing start fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/nope" "$TMP/allowed")"
eq "missing allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/nope")"
eq "empty allowed fails closed" "push:blocked paths=gate-unavailable" "$(bash "$G" "$TMP/start" "$TMP/empty")"
eq "bad start sha fails closed" "push:blocked paths=gate-unavailable" "$(echo deadbeef > "$TMP/bad"; bash "$G" "$TMP/bad" "$TMP/allowed")"
eq "start not ancestor" "push:blocked paths=gate-unavailable" "$(git checkout -q -b tmp HEAD~1; echo n > n.txt; git add n.txt; git commit -qm n; git rev-parse HEAD > "$TMP/s3"; git checkout -q feat; bash "$G" "$TMP/s3" "$TMP/allowed")"
# AC3: the gate decides before any push, and a Codex edit outside the branch diff is blocked; the gate never pushes.
eq "in-scope fix passes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
echo b2 >> b.txt; git commit -qam outside
eq "Codex edit outside the branch diff is blocked" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
eq "gate never pushes" "$REMOTE0" "$(git -C "$TMP/remote.git" rev-parse feat)"
eq "gate script has no push or gh call" "0" "$(grep -cE 'git push|gh (pr|api|repo)' "$G")"
git reset -q --hard HEAD~1
echo z >> .github/ci.yml; git commit -qam ci
eq "denylisted path even if allowed" "push:blocked paths=.github/ci.yml" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
git reset -q --hard HEAD~1
git mv b.txt c.txt; git commit -qm rename; printf 'a.txt\nc.txt\n' > "$TMP/allowed-c"
eq "rename source not hidden" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-c")"
git reset -q --hard HEAD~2
echo q > tmpf.txt; git add tmpf.txt; git commit -qm addf; git rm -q tmpf.txt; git commit -qm rmf
eq "add-then-remove forbidden file" "push:blocked paths=tmpf.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
git reset -q --hard HEAD~2
BASE=$(git rev-parse HEAD)
git checkout -q -b side; echo s > s.txt; git add s.txt; git commit -qm side
git checkout -q feat; echo a3 >> a.txt; git commit -qam mainline
git merge -q --no-ff --no-commit side; echo evil > b.txt; git add -A; git commit -qm merge
eq "merge commit out-of-scope path" "push:blocked paths=b.txt s.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
git reset -q --hard "$BASE"; git branch -q -D side
# N1-161: sibling new files. allowed-d adds a branch path in subdir d/ (the file need not exist locally).
printf 'a.txt\n.github/ci.yml\nd/x.txt\n' > "$TMP/allowed-d"
mkdir -p e; echo n > e/new.txt; git add e/new.txt; git commit -qm e
eq "new file in a dir with no allowed path" "push:blocked paths=e/new.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
echo n > .github/new.yml; git add .github/new.yml; git commit -qm ci2
eq "new CI file next to allowed CI file" "push:blocked paths=.github/new.yml" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
echo n > r.txt; git add r.txt; git commit -qm root
eq "new root file" "push:blocked paths=r.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/.hidden; git add d/.hidden; git commit -qm hidden
eq "new dot file in allowed dir" "push:blocked paths=d/.hidden" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d/sub; echo n > d/sub/f.txt; git add d/sub/f.txt; git commit -qm sub
eq "new file in a subdir of an allowed dir" "push:blocked paths=d/sub/f.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; printf '#!/bin/sh\n' > d/run.sh; chmod +x d/run.sh; ln -s ../a.txt d/ln; git add d/run.sh d/ln; git commit -qm modes
eq "new exec file and symlink in allowed dir" "push:blocked paths=d/ln d/run.sh" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/tmp.txt; git add d/tmp.txt; git commit -qm addt; git rm -q d/tmp.txt; git commit -qm rmt
eq "add-then-remove sibling stays blocked" "push:blocked paths=d/tmp.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/conftest.py; git add d/conftest.py; git commit -qm conftest
eq "new file with an extension not listed in that dir" "push:blocked paths=d/conftest.py" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/Makefile; git add d/Makefile; git commit -qm mk
eq "new extensionless file in allowed dir" "push:blocked paths=d/Makefile" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/credentials.txt; git add d/credentials.txt; git commit -qm cred
eq "deny regex beats sibling rule" "push:blocked paths=d/credentials.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
rm -f "$TMP/fix.patch"
DTIP=$(git rev-parse HEAD)
eq "denylisted block with patch arg: reset, no patch" "push:blocked paths=d/credentials.txt reset=$DTIP" "$(bash "$G" "$TMP/start" "$TMP/allowed-d" "$TMP/fix.patch")"
eq "denylisted block: patch not written" "none" "$([ -e "$TMP/fix.patch" ] && echo exists || echo none)"
eq "denylisted block: HEAD back at START" "$(cat "$TMP/start")" "$(git rev-parse HEAD)"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/CLAUDE.md; git add d/CLAUDE.md; git commit -qm claudemd
printf 'd/x.md\n' > "$TMP/allowed-md"
eq "loader basename not admitted as sibling" "push:blocked paths=d/CLAUDE.md" "$(bash "$G" "$TMP/start" "$TMP/allowed-md")"
git reset -q --hard "$BASE"
printf 'd/package.json\nd/source.js\n' > "$TMP/allowed-cfg"
mkdir -p d; echo '{}' > d/npm-shrinkwrap.json; git add d/npm-shrinkwrap.json; git commit -qm shrink
eq "lockfile not admitted as sibling" "push:blocked paths=d/npm-shrinkwrap.json" "$(bash "$G" "$TMP/start" "$TMP/allowed-cfg")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/eslint.config.js; git add d/eslint.config.js; git commit -qm eslint
eq "tool config not admitted as sibling" "push:blocked paths=d/eslint.config.js" "$(bash "$G" "$TMP/start" "$TMP/allowed-cfg")"
git reset -q --hard "$BASE"
mkdir -p d; echo n > d/AGENTS.override.md; git add d/AGENTS.override.md; git commit -qm agentsdot
eq "dotted loader basename not admitted as sibling" "push:blocked paths=d/AGENTS.override.md" "$(bash "$G" "$TMP/start" "$TMP/allowed-md")"
git reset -q --hard "$BASE"
git checkout -q -b side; mkdir -p d; echo 1 > d/m.txt; git add d/m.txt; git commit -qm s1; git checkout -q feat
mkdir -p d; echo 2 > d/m.txt; git add d/m.txt; git commit -qm s2; git merge -q side >/dev/null 2>&1
rm -f d/m.txt; ln -s ../a.txt d/m.txt; git add d/m.txt; git commit -qm mergesym
rm d/m.txt; echo n > d/m.txt; git add d/m.txt; git commit -qm mergereg
eq "symlink recorded only by a merge stays blocked" "push:blocked paths=d/m.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"; git branch -q -D side
mkdir -p d; ln -s ../a.txt d/sl.txt; git add d/sl.txt; git commit -qm sym1
rm d/sl.txt; echo n > d/sl.txt; git add d/sl.txt; git commit -qm sym2
eq "symlink in an intermediate commit stays blocked" "push:blocked paths=d/sl.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
git reset -q --hard "$BASE"
# N1-161: with PATCH_FILE, blocked fixes are saved and the branch reset to START
START=$(cat "$TMP/start")
echo b3 >> b.txt; git commit -qam outside2; TIP=$(git rev-parse HEAD)
eq "no patch arg: blocked line unchanged" "push:blocked paths=b.txt" "$(bash "$G" "$TMP/start" "$TMP/allowed")"
eq "no patch arg: HEAD untouched" "$TIP" "$(git rev-parse HEAD)"
eq "blocked fix saved and reset" "push:blocked paths=b.txt reset=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" "$TMP/fix.patch")"
eq "blocked reset lands on START" "$START" "$(git rev-parse HEAD)"
eq "saved patch applies on START" "ok" "$([ -s "$TMP/fix.patch" ] && git apply --check "$TMP/fix.patch" && echo ok)"
eq "saved patch is mode 600" "600" "$(stat -c %a "$TMP/fix.patch" 2>/dev/null || stat -f %Lp "$TMP/fix.patch")"
git reset -q --hard "$TIP"; rm -f "$TMP/fix.patch"
echo dirty >> b.txt
eq "reset refused with overlapping local edit" "push:blocked paths=b.txt kept=$TIP" "$(bash "$G" "$TMP/start" "$TMP/allowed" "$TMP/fix.patch")"
eq "kept leaves HEAD at tip" "$TIP" "$(git rev-parse HEAD)"
git checkout -q -- b.txt; rm -f "$TMP/fix.patch"
git reset -q --hard "$BASE"
echo a4 >> a.txt; git commit -qam infix; TIP=$(git rev-parse HEAD)
eq "in-scope change with patch arg passes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed" "$TMP/fix.patch")"
eq "push:ok keeps HEAD and writes no patch" "$TIP none" "$(git rev-parse HEAD) $([ -e "$TMP/fix.patch" ] && echo exists || echo none)"
mkdir -p d; echo n > d/new.txt; git add d/new.txt; git commit -qm sibling
eq "new regular file next to an allowed path passes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
echo n > "d/with space.txt"; git add "d/with space.txt"; git commit -qm spaced
eq "new file with a space in its name passes" "push:ok" "$(bash "$G" "$TMP/start" "$TMP/allowed-d")"
eq "remote still untouched after every case" "$REMOTE0" "$(git -C "$TMP/remote.git" rev-parse feat)"
exit $FAIL
