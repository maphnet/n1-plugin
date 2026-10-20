#!/usr/bin/env bash
# N1-110: n1-finish entry call. One Bash call prints config, merge permission, the
# pending-deploy check, the PR and only the step files that apply.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
FAIL=0
SKILL=skills/n1-finish/SKILL.md
unset N1_QUEUE_RUN_ID N1_HEADLESS N1_RUN_ID

ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; FAIL=1; }
has() { if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else no "$1"; fi; }
lacks() { if grep -qF -- "$2" <<<"$OUT"; then no "$1"; else ok "$1"; fi; }

# Static: step files are no longer read one by one.
if grep -qE '^ *Read `<N1_ROOT>/skills/n1-finish/steps/' "$SKILL"; then
    no "SKILL.md has no per-step Read lines"
else
    ok "SKILL.md has no per-step Read lines"
fi

# Entry snippet = first bash block of SKILL.md, preamble pointed at this checkout.
ENTRY=$(awk '/^```bash/{b=1;next} b&&/^```/{exit} b' "$SKILL" \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e 's/<ID>/T-1/' -e 's/<PR>//')

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/memory/T-1" "$T/repo"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in auth) exit 0 ;; pr) echo PRVIEW-CALLED ;; esac
EOF
chmod +x "$T/bin/gh"
git -C "$T/repo" init -q -b main
git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m init
SHA=$(git -C "$T/repo" rev-parse HEAD)
echo "ticket body marker" > "$T/home/memory/T-1/ticket.md"

run() { # <config-json> <overview frontmatter lines>
    printf '%s\n' "$1" > "$T/home/config.json"
    printf -- '---\n%s\n---\n# T-1\n' "$2" > "$T/home/memory/T-1/overview.md"
    OUT=$(cd "$T/repo" && N1_ROOT="$REPO" N1_HOME="$T/home" N1_HEADLESS="${HL:-}" PATH="$T/bin:$PATH" bash -c "$ENTRY" 2>&1)
}

# 1. Typical run: deploy watch off, no delivery, done status configured.
run '{"git":{"defaultBranch":"main"},"tracker":{"mcp":"jira","statuses":{"done":"Done"}}}' 'deploy_pending: false'
has "typical: gh pr view runs" "PRVIEW-CALLED"
has "typical: merge permission printed" "merge:denied"
has "typical: gh auth printed" "gh:ok"
has "typical: prints 01" "=== steps/01-resolve-target"
has "typical: prints 02" "=== steps/02-merge"
has "typical: prints 04" "=== steps/04-close-ticket"
has "typical: prints 05" "=== steps/05-telemetry-followup"
has "typical: prints 06" "=== steps/06-cleanup"
has "typical: prints deployment-actions" "=== ../../references/deployment-actions"
has "typical: prints ticket.md" "ticket body marker"
lacks "typical: skips 03-deploy" "=== steps/03-deploy"
lacks "typical: skips 03b" "=== steps/03b-ssh-deploy"
lacks "typical: skips done-status recovery" "=== references/done-status-recovery"
if grep -qxF '(missing)' <<<"$OUT"; then no "typical: every printed file exists"; else ok "typical: every printed file exists"; fi

lacks "typical: no headless flag" "headless:yes"
HL=1 run '{"git":{"defaultBranch":"main"}}' 'deploy_pending: false'
has "headless: flag printed" "headless:yes"
HL=

# 2. Conditional files: deploy watch on, ssh delivery, done status absent.
run '{"finishWork":{"deployWatch":{"enabled":true}},"delivery":{"mode":"ssh"},"tracker":{"mcp":"jira"}}' 'deploy_pending: false'
has "conditional: prints 03-deploy" "=== steps/03-deploy"
has "conditional: prints 03b" "=== steps/03b-ssh-deploy"
has "conditional: prints done-status recovery" "=== references/done-status-recovery"

# 3. Pending-deploy resume with a valid recorded SHA skips the PR lookup.
run '{"git":{"defaultBranch":"main"}}' "deploy_pending: true
deploy_merge_sha: $SHA"
has "resume: sha validated" "deploy-pending:true sha:$SHA sha-valid:true"
lacks "resume: skips gh pr view" "PRVIEW-CALLED"

# 4. A malformed recorded SHA is not trusted; normal PR lookup runs.
run '{"git":{"defaultBranch":"main"}}' 'deploy_pending: true
deploy_merge_sha: notasha'
has "resume: bad sha rejected" "sha-valid:false"
has "resume: bad sha falls back to PR lookup" "PRVIEW-CALLED"

exit $FAIL
