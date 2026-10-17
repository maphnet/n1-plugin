#!/usr/bin/env bash
# N1-88: after a custom release procedure, n1-release checks that a GitHub Release exists and offers one.
set -uo pipefail
cd "$(dirname "$0")/.."
FAIL=0
R2=skills/n1-release/steps/02-confirm-execute.md
R4=skills/n1-release/steps/04-report.md

check() { # <label> <extended-regex> <file>
    if grep -qE -- "$2" "$3" 2>/dev/null; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
before() { # <label> <fixed-a> <fixed-b> <file>: first occurrence of a precedes first occurrence of b
    local a b
    a=$(grep -nF -m1 -- "$2" "$4" 2>/dev/null | cut -d: -f1); b=$(grep -nF -m1 -- "$3" "$4" 2>/dev/null | cut -d: -f1)
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAIL=1; fi
}
expect() { # <label> <want> <got>
    if [ "$3" = "$2" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}

# --- behavior: the Release-check snippet against a real local origin and a stubbed gh
SNIPPET=$(awk 'index($0, "### Release check") == 1 {f = 1; next} f && /^```bash/ {b = 1; next} b && /^```/ {exit} b' "$R2")
if [ -n "$SNIPPET" ]; then echo "PASS: release check snippet present"; else echo "FAIL: release check snippet missing"; FAIL=1; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "release view") [ "${GH_RELEASE_EXISTS:-0}" = 1 ] ;;
    "run list") [ -z "${GH_RUN_STATUS:-}" ] || printf '%s\n' "$GH_RUN_STATUS" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
git init -q --bare "$T/origin.git"
git init -q -b main "$T/work"
git -C "$T/work" remote add origin "$T/origin.git"
git -C "$T/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
git -C "$T/work" -c user.email=t@t -c user.name=t tag -a v1.0.0 -m t   # annotated, like the built-in flow: exercises the ^{commit} peel

verdict() { # <release-exists 0|1> [run-status]
    (cd "$T/work" && export GH_RELEASE_EXISTS="$1" GH_RUN_STATUS="${2:-}" \
        && PATH="$T/bin:$PATH" TAG=v1.0.0 bash -c "$SNIPPET" 2>/dev/null)
}

expect "existing Release -> exists" "release:exists" "$(verdict 1)"
expect "tag not on origin -> no offer" "release:missing-no-remote-tag" "$(verdict 0)"
git -C "$T/work" push -q origin v1.0.0 2>/dev/null
expect "no release workflow, unrelated run active -> offer" "release:missing-offer" "$(verdict 0 in_progress)"
mkdir -p "$T/work/.github/workflows"
printf 'on:\n  push:\n    tags: ["v*"]\njobs:\n  release:\n    runs-on: ubuntu-latest\n    steps:\n      - run: gh release create "$GITHUB_REF_NAME" --generate-notes\n' \
    > "$T/work/.github/workflows/release.yml"
expect "release workflow still running -> no offer" "release:missing-workflow-running" "$(verdict 0 in_progress)"
expect "release workflow queued -> no offer" "release:missing-workflow-running" "$(verdict 0 queued)"
expect "release workflow finished, no Release -> offer" "release:missing-offer" "$(verdict 0 completed)"
expect "release workflow, no runs -> offer" "release:missing-offer" "$(verdict 0)"

# --- wiring: gate, ordering, offer, report
check "gate promises a Release for built-in or gh-release procedures" '^- `GitHub Release: will be created`' "$R2"
check "gate warns when a custom procedure creates no Release" 'GitHub Release: will NOT be created by this procedure' "$R2"
before "release check follows the procedure walk" "**Walk each step**" "### Release check" "$R2"
check "release check is skipped on abort" 'skipped when the walk was aborted' "$R2"
check "release check offers Create/Skip" '^  1 — Create$' "$R2"
check "release check honours release.draft" 'add `--draft` when `release.draft` is true' "$R2"
check "custom report has a Release line" '^Release: .*missing \(declined\)' "$R4"

exit $FAIL
