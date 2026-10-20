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

# Static: every step/reference file named in the Steps list is either in the always-read
# sentence or a conditional read-also candidate in the entry snippet.
SNIP=$(awk '/^```bash/{b=1;next} b&&/^```/{exit} b' "$SKILL")
HEAD=$(awk '/^## Entry/{e=1} /^```bash/{exit} e' "$SKILL")
for f in $(awk '/^## Steps/{s=1} s' "$SKILL" | grep -oE 'steps/[0-9a-z-]+\.md' | sort -u); do
    if grep -qF "${f#steps/}" <<<"$HEAD" || grep -qF "$f" <<<"$SNIP"; then ok "entry covers $f"; else no "entry covers $f"; fi
done

# Entry snippet = first bash block of SKILL.md, preamble pointed at this checkout.
ENTRY=$(awk '/^```bash/{b=1;next} b&&/^```/{exit} b' "$SKILL" \
    | sed -e 's#^source ~/.n1/preamble.sh$#source "$N1_ROOT/lib/preamble.sh"#' -e "s/<ID>/\${TID-T-1}/" -e 's/<PR>/\${TPR-}/')

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/memory/T-1" "$T/repo"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in auth) exit ${GHAUTH:-0} ;; pr) echo PRVIEW-CALLED ;; esac
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
has "typical: read-also lists ticket.md" "$T/home/memory/T-1/ticket.md"
has "typical: read-also lists overview.md" "$T/home/memory/T-1/overview.md"
lacks "typical: does not cat step files" "=== steps/"
lacks "typical: does not cat ticket body" "ticket body marker"
SZ=$(wc -c <<<"$OUT"); if [ "$SZ" -lt 20000 ]; then ok "typical: output $SZ bytes < 20000"; else no "typical: output $SZ bytes < 20000"; fi
has "typical: id printed" "id=T-1"
has "typical: prMode derived draft" "prMode=draft"
lacks "typical: skips 03-deploy" "steps/03-deploy.md"
lacks "typical: skips 03b" "steps/03b-ssh-deploy.md"
lacks "typical: skips done-status recovery" "done-status-recovery.md"

if grep -qxF "headless:yes" <<<"$OUT"; then no "typical: no headless flag"; else ok "typical: no headless flag"; fi
HL=1 run '{"git":{"defaultBranch":"main"}}' 'deploy_pending: false'
if grep -qxF "headless:yes" <<<"$OUT"; then ok "headless: flag printed"; else no "headless: flag printed"; fi
HL=

# 2. Conditional files: deploy watch on, ssh delivery, done status absent.
run '{"finishWork":{"deployWatch":{"enabled":true}},"delivery":{"mode":"ssh"},"tracker":{"mcp":"jira"}}' 'deploy_pending: false'
has "conditional: lists 03-deploy" "steps/03-deploy.md"
has "conditional: lists 03b" "steps/03b-ssh-deploy.md"
has "conditional: lists done-status recovery" "references/done-status-recovery.md"
SZ=$(wc -c <<<"$OUT"); if [ "$SZ" -lt 20000 ]; then ok "conditional: output $SZ bytes < 20000"; else no "conditional: output $SZ bytes < 20000"; fi
run '{"finishWork":{"closeTicket":false},"tracker":{"mcp":"jira"}}' 'deploy_pending: false'
lacks "closeTicket=false: no done-status recovery" "done-status-recovery.md"

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

# 5. gh unauthenticated: no PR lookup.
GHAUTH=1 run '{"git":{"defaultBranch":"main"}}' 'deploy_pending: false'
has "unauth: gh:unauthenticated" "gh:unauthenticated"
lacks "unauth: skips gh pr view" "PRVIEW-CALLED"
GHAUTH=0

# 6. prMode derivation.
run '{"git":{"prMode":"skip","draftPR":true}}' 'deploy_pending: false'
has "prMode: explicit skip wins" "prMode=skip"
run '{"git":{"draftPR":false}}' 'deploy_pending: false'
has "prMode: draftPR false -> ready" "prMode=ready"

# 7. Well-formed SHA that is not an ancestor.
git -C "$T/repo" checkout -q -b side
git -C "$T/repo" -c user.name=t -c user.email=t@t -c commit.gpgSign=false commit -q --allow-empty -m side
SIDE=$(git -C "$T/repo" rev-parse HEAD)
git -C "$T/repo" checkout -q main
run '{"git":{"defaultBranch":"main"}}' "deploy_pending: true
deploy_merge_sha: $SIDE"
has "resume: non-ancestor sha rejected" "sha-valid:false"

# 8. ID handling: derived from branch, invalid rejected.
git -C "$T/repo" checkout -q -b "me/T-1-feature"
TID= run '{"tracker":{"prefix":"T"}}' 'deploy_pending: false'
has "id: derived from branch" "id=T-1"
has "id: derived id reads overview" "deploy-pending:false"
git -C "$T/repo" checkout -q main
TID='x;rm -rf' run '{"tracker":{"prefix":"T"}}' 'deploy_pending: false'
has "id: invalid rejected" "id:invalid"
TPR='12;x' run '{"git":{"defaultBranch":"main"}}' 'deploy_pending: false'
has "pr: non-digit dropped" "PRVIEW-CALLED"

exit $FAIL
